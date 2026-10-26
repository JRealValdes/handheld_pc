# DualSense BT disconnect after game launch — knowledge

Status: **workaround confirmed** (2026-10-26). Steam **PlayStation Controller Support** must stay **Disabled**. That client driver holds `/dev/hidraw*` and the HID session drops a few seconds into the game while the Bluetooth ACL stays up.

## 1. Observed symptom

| Step | Result |
|------|--------|
| Pair DualSense over Bluetooth | OK |
| Use desktop / Steam Big Picture / Steam detects DualSense | OK |
| Launch game (Marvel Rivals) | Controller drops after a few seconds |

Important distinction when reading logs:

- **Bluetooth link drop** — device leaves BlueZ (`Disconnected`, HCI reason, `hci0: ... disconnected`).
- **Input path drop** — BT stays connected but Steam / SDL / the game lose the pad (hidraw reopen, exclusive grab, Steam Input).

The debug script tries to tell these apart.

## 2. Stack (Ubuntu + Steam + DualSense BT)

```text
DualSense (BT)
  → BlueZ (bluetoothd) + kernel HCI
  → hid-playstation (or hid-sony on older kernels)
  → /dev/hidraw* + /dev/input/event*
  → Steam Input (optional remap / exclusive)
  → game (SDL / Proton / native)
```

Marvel Rivals on Linux is typically **Proton**. Proton + Steam Input + DualSense BT is a frequent conflict surface (extra feature reports, haptics, LED, audio headset profile).

## 3. Hypotheses to confirm/reject (ordered)

| ID | Layer | Idea | What dump should show |
|----|-------|------|------------------------|
| H1 | BlueZ / HCI | Link supervision timeout or local host terminate under game load | `btmon` / `dmesg` disconnect reason (e.g. 0x08 timeout, 0x16 local host) |
| H2 | Kernel HID | `hid-playstation` fault / reset when advanced reports start | `dmesg` hid errors around disconnect time |
| H3 | Steam Input | Steam takes exclusive access; game also opens device → drop or reopen loop | Steam logs + hidraw open/close; BT may stay up |
| H7 | BlueZ UHID | Userspace HID (`UserspaceHID=true`) tears down or breaks uhid while ACL stays Connected | Connected yes + zero `/sys/.../uhid/0005:054C:0CE6.*` + no event/hidraw |
| H4 | Dual profile | Controller exposes HID + audio; A2DP/HFP renegotiation when game starts audio | bluetoothd profile disconnect / `a2dp` / `headset` lines |
| H5 | Power mgmt | Runtime PM / autosuspend on BT USB dongle under load | `dmesg` autosuspend / xhci; dongle-specific |
| H6 | User-space fight | Another daemon (`ds4drv`, `joycond`, `sc-controller`, Flatpak portal) grabs the pad | processes holding `/dev/hidraw*` / `lsof` |

## 4. Disconnect reason cheat sheet (HCI)

Seen in `btmon` / kernel messages:

| Code | Meaning (short) | Typical next step |
|------|-----------------|-------------------|
| `0x08` | Connection timeout | RF/interference, dongle, distance, BT coexistence with Wi‑Fi |
| `0x13` | Remote user terminated | Pad powered off / pad-side reset |
| `0x16` | Local host terminated | Something on PC closed the link (BlueZ, stack, policy) |
| `0x22` | LMP response timeout | Similar to flaky link / firmware |
| `0x3e` | Connection failed to be established | Reconnect race after drop |

## 5. Verification checklist (after a capture)

- [x] Was MAC still in `bluetoothctl devices Connected` after drop? → **yes** (Capture 1)
- [x] HCI reason code present? → **no** (Capture 1: empty btmon disconnect matches)
- [x] Steam Input: Marvel Rivals with Steam Input **Forced Off** → **still drops** (2026-10-26)
- [x] While “dead”: `./probe-dualsense-alive.sh` → **Connected yes, event/hidraw/uhid = none** (2026-10-26)
- [ ] `./watch-hid-death.sh` while launching game — who removes uhid? (udev + bluetoothd + btmon)
- [ ] Reversible test: `UserspaceHID=false` in `/etc/bluetooth/input.conf` + restart bluetooth + re-pair/reconnect
- [ ] Wired USB: same game drop?
- [ ] Another BT game / non-Proton title: same drop?

## 6. Anti-patterns

- Do not install `ds4drv` / random DualShock userspace stacks on modern kernels (conflicts with `hid-playstation`).
- Do not randomly set `ControllerFirmware` / disable BlueZ plugins without a dump.
- Do not “fix” by only disabling Steam Input forever until H3 is confirmed — document it as a test, not a cure.
- Do not invent an uninstaller until a real overlay fix exists.

## 7. Useful one-liners (manual)

```bash
# Connected DualSense-like devices
bluetoothctl devices Connected

# Kernel HID noise
journalctl -k -f | grep -iE 'hid|bluetooth|playstation|sony'

# Who holds hidraw
ls -l /dev/hidraw*; sudo lsof /dev/hidraw* 2>/dev/null

# Steam Input test: per-game → Controller → Disable Steam Input
```

## 8. Case log

| Date | Dump / notes | Conclusion |
|------|--------------|------------|
| 2026-10-26 | `dualsense-bt-disconnect-20261026T072615Z` (sudo → landed under `/root/Downloads`). MAC `24:A6:FA:F4:E2:4C` still **Connected** after symptom. No HCI disconnect in btmon/journals. Kernel: `hid-playstation` DualSense BT on uhid (`054C:0CE6`), fw `0x0110002a`. Host is real PS5 Salina hardware + Ubuntu (`Linux 7.1.7`). | **Reject H1 as primary.** |
| 2026-10-26 | Marvel Rivals + Steam Input **Forced Off** → still drops | **Reject “Steam Input alone” as the fix.** |
| 2026-10-26 | `probe-dualsense-alive` after drop: `Connected: yes`, `main_event_nodes: none`, `hidraw_nodes: none`. | **Broken state = HID gone, ACL stays.** |
| 2026-10-26 | `dualsense-hid-death-20261026T073956Z`: before `uhid/...0CE6.0007` + event6/7/8; after Connected still, uhid **gone**, hidraw4 gone. udev only `remove` (no radio drop). `bluetoothd` `hidp_send_message() BT socket write error: EAGAIN (11)` at 08:42:12, same window. btmon: steady DualSense **output** `a2 31 …` (~20 ms) from bluetoothd while input `a1 31` flows. | HID teardown is tied to **output-report writes failing** (LED/rumble/HIDAPI), not HCI disconnect. |
| 2026-10-26 | `UserspaceHID=false` + bluetooth restart (BlueZ 5.85). Kernel HIDP path (`hci0/.../0005:054C:0CE6.0008` at 08:44:08). `ioctl_is_connected() Can't get HIDP connection info` at 08:44:07 and 08:44:39. Re-register `.0009` at 08:44:41. User: still dies in Marvel Rivals; mashing buttons/trackpad revives DualSense ~1s then dies again. Trackpad sometimes seen as mouse. | **Reject H7 as the fix.** HIDP flaps the same way. 1s revival = HID recreated by input, then killed again (likely another output-report burst). |
| 2026-10-26 | Launch option `SDL_JOYSTICK_HIDAPI_PS5=0` → still dies, ~1s resurrection. Kernel still has HIDP `.000A` afterwards. `steam` (pid 11435) holds `/dev/hidraw4`. `gnome-shell` holds touchpad `event8`. Game process already gone. | **Reject game SDL HIDAPI as the only writer.** Steam client owns the hidraw. |
| 2026-10-26 | Steam → Controller → **PlayStation Controller Support = Disabled**, Steam fully restarted, DualSense reconnected, Marvel Rivals launched. Pad stayed up. | **Workaround confirmed.** Steam’s PS driver was the writer that killed HID. |

## 9. Working configuration

| Knob | Value when it started working |
|------|--------------------------------|
| Steam PlayStation Controller Support | **Disabled** (the change that fixed it) |
| `/etc/bluetooth/input.conf` `UserspaceHID` | `false` (still set; not proven required) |
| Marvel Rivals launch options | `SDL_JOYSTICK_HIDAPI_PS5=0 %command%` (still set; not proven required) |
| Per-game Steam Input | had been Forced Off earlier |

Do not re-enable PlayStation Controller Support to chase button icons. That setting is what opens hidraw and reproduces the drop.

### Glyphs (nice-to-have, not done)

Marvel Rivals has no in-game glyph toggle. On PC it shows PlayStation icons only when it sees a native DualSense; Steam’s PS support is the usual way to get that, and that path is the bug here. Proton otherwise feeds the Windows build an XInput pad, so prompts stay Xbox/PC.

Safe experiment, one knob: keep PS support **Disabled**, remove only `SDL_JOYSTICK_HIDAPI_PS5=0`, relaunch. If the pad drops, restore the launch option.

### Capture 1 — what “disconnect” is *not*

Not a full BlueZ ACL drop. After probe: also **not** “game ignores a live kernel pad” — there is no kernel pad left.

### Working vs broken

| | Working (Capture 1 connect) | Broken (alive probe) |
|--|-----------------------------|----------------------|
| `bluetoothctl` Connected | yes | yes |
| `hid-playstation` / uhid | present (`uhid/0005:054C:0CE6.*`) | **absent** |
| `/dev/input/event*` DualSense | present | **absent** |
| hidraw DualSense | present | **absent** |

Related upstream: BlueZ UHID / DualSense quirks (`UserspaceHID`); Connected-but-dead after HID path issues is a known class of bugs. Default is often UHID (`UserspaceHID=true`).

### Next experiment (ordered)

1. ~~Steam Input Forced Off~~ → still broken.
2. ~~Alive probe~~ → HID nodes gone.
3. ~~watch-hid-death~~ → uhid removed; `hidp_send_message` EAGAIN; output `a2 31` flood.
4. ~~`UserspaceHID=false`~~ → kernel HIDP, still dies, 1s revive-on-button-mash.
5. ~~`SDL_JOYSTICK_HIDAPI_PS5=0`~~ → still dies, ~1s resurrection (08:52). Kernel kept HIDP `.000A` (event6/7/8 + hidraw4). After the game exited, **`steam` pid still holds `/dev/hidraw4`**. `gnome-shell` holds the touchpad node (`event8`) — matches “trackpad as mouse”.
6. ~~PlayStation Controller Support Disabled~~ → **pad stays up.** This is the workaround.
