# Legion Go 2 — game pad missing after resume

Durable context for: suspend in **Gaming mode with a game open**, resume succeeds, **the game no longer sees the pad (sticks included)**. Steam UI still works, sticks included. The left Legion button still opens Steam OS.

Distinct from [suspend-wake](../suspend-wake/KNOWLEDGE.md) (machine never finishes s2idle) and from [gyroscope-imu-udev](../gyroscope-imu-udev/KNOWLEDGE.md).

**Status (2026-10-30):** Open. The in-game case is not captured yet. A Desktop resume the same day is a different observation (see §3) and is not this bug. Watcher keeps the last 20 suspends; look them up by clock time.

**Scope of truth:** This machine. SteamOS `3.9.5` / `BUILD_ID=20261023.100`, kernel `7.2.7-valve2-2-neptune-72-g31504582a073`, `inputplumber 0.78.0`, DMI `83N0`, USB `17ef:61eb`. User report below is what they have seen several times in Gaming mode.

---

## 0. When the user reports a bad resume at a clock time

They will switch to Desktop and say the resume went bad at a local time (24h, e.g. `21:40`). Do this before theorising:

1. Read this file. The reported bug is **game dead, Steam UI alive including sticks**.
2. Confirm the watcher is running: `systemctl is-active legion-go2-resume-gamepad-trace.service`.
3. Find that resume, not whichever cycle is newest:

```bash
cd "devices/legion-go-2/fixes/resume-gamepad"
./trace-legion-go2-resume-gamepad.sh find "21:40"
```

Replace `21:40` with the time they gave. Match the `resume` line. `LATEST` may be a later suspend or a manual snapshot.

4. In that cycle directory, read `summary.txt`, then `post-0s.txt` / `post-15s.txt` signals, `steam-post-0s-controller.txt`, `steam-post-15s-controller.txt`, `steam-*-controller_ui.txt`, `journal-inputplumber.txt`, and the open-fd section of `post-15s.txt`.
5. Decide using §4. Record the conclusion back into §3. Do not restart InputPlumber or change targets until that cycle is read.

Switching Gaming mode → Desktop is **not** a suspend. It does not create a cycle and it does not delete old ones (`~/legion-go2-resume-gamepad/cycles/`, last 20, plus append-only `~/legion-go2-resume-gamepad/index.txt`). Steam itself may rotate `controller.txt` when Desktop starts; the cycle dir already holds copies taken at resume (`steam-post-0s-*` immediately, `steam-post-15s-*` fifteen seconds later). Read those copies, not only the live Steam log.

If `find` shows nothing, the service was not running for that suspend. Say so. Do not invent a cycle.

---

## 1. Why the symptom can split in two

```text
USB 17ef:61eb  (hid-lenovo-go)
        │
        ├─ hidraw gamepad  ── InputPlumber source
        │                         │
        │                         ├─ target keyboard → evdev "InputPlumber Keyboard"
        │                         │     Legion / guide key. Session can read this.
        │                         │     gamescope uses it for the home button.
        │                         │
        │                         └─ target deck-uhid → uhid 28de:12fb
        │                               hidraw "Legion Go 2 Controller"
        │                               Steam opens this (controller index 15).
        │                               The game’s pad is this device, via Steam Input.
        │
        └─ physical keyboard evdev (grabbed by InputPlumber, not what the game reads)
```

Steam UI sticks working means Steam has a live gamepad again after resume. The game process is the one that does not pick it up. A working Legion button alone would not prove that; the user has confirmed the sticks work in the Steam UI and do not work in the game.

`steamos-manager` sets targets `deck-uhid`, `keyboard`, `mouse` (profile default before that hand-off is `xbox-elite` + mouse + keyboard + touchpad).

---

## 2. What a healthy resume looks like in the logs

Same USB drop on the way into sleep, then on the way out:

| Signal | Healthy (seen 14:53 and 14:19) | Broken reopen (seen 16:20) |
|--------|--------------------------------|----------------------------|
| `controller.txt` | `hid_read failure` → later `Steam controller device opened for index 15` | `hid_read failure` → `Unable to open local device: /dev/hidrawN` and **no** later `device opened` |
| `controller_ui.txt` | `Controller 15 disconnected` then `Controller 15 connected` | `disconnected` and no later `connected` |
| deck hidraw ACL | user `deck` effective `rw` | mode `000`, `mask::---`, `user:deck` effective `---` |
| InputPlumber Keyboard evdev | mode `660`, mask `rw` | same — still openable |
| `inputplumber devices order` | contains `CompositeDevice0` at least briefly | logged `Gamepad order: []` after the retarget to `deck-uhid` |

---

## 3. Observed cycle — 2026-10-30 16:19 → 16:20 (Desktop)

Not an in-game reproduction. Cursor / `kwin_wayland` were up. Steam client stayed running. Useful because it is the same USB drop the game case hits.

**Sleep (16:19:43)**

- InputPlumber: `evdev://event2` “No such device”, `hidraw://hidraw1` disconnected, `CompositeDevice0` stopped, `Gamepad order: []`.
- Steam: `Controller device closed after hid_read failure`, PollState `2 → 0`.
- `controller_ui.txt`: `Controller 15 disconnected`.

**Resume (16:20:28–16:20:30)**

- `Unable to create initialized UdevDevice for /dev/input/event2 after 80 attempts.`
- Composite device created from the Legion **keyboard** evdev first, then mouse, touchpad, `hidraw1`, xbox evdev.
- Targets set first to the profile default (`xbox-elite`, mouse, keyboard, touchpad).
- Three `add_source_device` failures: `Device or resource busy` (os error 16).
- Targets then replaced with `deck-uhid`, keyboard, mouse. Kernel creates `hidraw8` `28de:12fb` “Legion Go 2 Controller”.
- `Gamepad order: []` twice after that retarget.
- Steam finds `/dev/hidraw8` and logs `Unable to open local device: /dev/hidraw8` at 16:20:29 and 16:20:30. No `device opened` after that.
- `controller_ui.txt` has no `Controller 15 connected` after 16:19:43.

**Still true at 16:43** (baseline snapshot `~/legion-go2-resume-gamepad/cycles/cycle-20261030-164303`):

- Composite device 0 exists. Sources: `/dev/input/event2`, `/dev/hidraw1`. Targets: mouse, `deck-uhid`, keyboard.
- `devices order` empty.
- `hidraw8` mode `000`, ACL mask `---`, deck’s effective access none.
- InputPlumber Keyboard (`event20` this boot) mode `660`, mask `rw`, deck can open it.

So after this resume the virtual pad node exists, root InputPlumber can feed it, and the logged-in user (Steam) cannot open it. The keyboard target the home button uses is unaffected.

---

## 4. Hypotheses (ranked for the Gaming-mode report)

### H2 — Steam UI rebinds, the running game does not (leading)

**What:** Suspend drops controller 15. On resume Steam opens the new deck-uhid and configures it for the Steam UI. The game that was already running keeps the old slot (Steam Input config not reloaded for that appid, or Proton/XInput still bound to the device node that vanished).

**Why it fits the report:** Sticks work in the Steam UI after the bad resume, and do not work in the game. That requires a live gamepad path into Steam. It does not require the game process to have reopened anything.

**What the cycle should show:**

- `steam-post-0s-controller.txt` or `steam-post-15s-controller.txt`: `device opened` after the `hid_read failure` (not only `Unable to open`).
- `steam-*-controller_ui.txt`: `Controller 15 disconnected` then `connected`, and a config load for the client UI / `basicui`.
- The game appid from `pre` (`OnFocusWindowChanged` / transient `app-steam-app*`) does **not** get a new `Loaded Config` after `resume`.
- `post-15s.txt` open fds: the game (or `steam`) holding a `(deleted)` hidraw or js node, with a new hidraw present.

### H1 — Steam never reopens deck-uhid (seen on Desktop, poor fit for this report)

**What:** USB drop closes controller 15. The new `/dev/hidraw*` stays mode `000` / ACL mask `---`, Steam logs `Unable to open`, and never retries.

**Where it was seen:** §3, Desktop resume at 16:20, no game in front. Steam UI sticks were not checked.

**Why it is a poor fit for the reported bug:** if Steam cannot open the hidraw, the Steam UI should not have working sticks either. Keep it only if a Gaming-mode cycle shows `Unable to open` and no later `device opened` **and** the user still says UI sticks worked.

### H3 — Composite device comes back without a gamepad source

**What:** EBUSY or the “event2 after 80 attempts” race leaves the composite device on keyboard/mouse only, or `devices order` stays empty so nothing is player 1.

**What the dump should show:** `device 0 info` sources missing the `17ef:61eb` hidraw at `post-15s`. Steam UI sticks working argues against this: Steam is receiving a gamepad. `ORDER=empty` alone is not enough; it was empty on the Desktop cycle in §3.

### H4 — Ruled out as the whole story

- Suspend never completing ([suspend-wake](../suspend-wake/KNOWLEDGE.md)): this bug resumes.
- Gyro udev / IMU attrs: different chain; home vs game is not an IMU failure.
- Bluetooth drop: the onboard pad is USB `17ef:61eb`, not a BT HID.

---

## 5. Tooling

```bash
cd devices/legion-go-2/fixes/resume-gamepad
./trace-legion-go2-resume-gamepad.sh install      # systemd unit, every suspend
./trace-legion-go2-resume-gamepad.sh status
./trace-legion-go2-resume-gamepad.sh find 21:40   # cycle for that local resume time
./trace-legion-go2-resume-gamepad.sh find         # last index lines
./trace-legion-go2-resume-gamepad.sh uninstall    # stop and delete the systemd unit; keeps dumps
```

`install` listens to logind `PrepareForSleep` (no sleep inhibitor, no `/usr` hook). One directory per suspend:

| File | When |
|------|------|
| `when.txt` | `suspend` and `resume` local timestamps |
| `pre.txt` + `steam-pre-*` | Just before suspend (which game was focused) |
| `steam-post-0s-*` | Steam controller logs copied at resume, before Desktop can rotate them |
| `post-0s.txt` / `post-5s.txt` / `post-15s.txt` | Device state after resume |
| `steam-post-15s-*` | Steam logs again, including `controller*.previous.txt` if Steam already rotated |
| `journal-inputplumber.txt`, `journal-kernel.txt` | From the pre timestamp |
| `summary.txt` | Order, ACL, Steam open/fail, UI focus lines |

`~/legion-go2-resume-gamepad/index.txt` is append-only (one line per event). Last **20** cycle directories are kept. Gaming mode → Desktop does not remove them.

The unit runs as root so post dumps include who holds `hidraw` / `js` (including `(deleted)` fds). Files are chowned to `deck`.

---

## 6. Anti-patterns

- Restarting InputPlumber, flipping `deck-uhid` vs `xbox-elite`, or editing gyro udev to “fix” this before a cycle is captured.
- Reading a working Legion button as “the controller device is fine.”
- Installing a `/usr/lib/systemd/system-sleep/` hook for this. SteamOS updates drop those, and this watcher does not need to delay suspend. See suspend-wake for that constraint.
- Declaring H1 confirmed from the Desktop cycle alone.
- Treating `LATEST` as the bad resume after the user has come back via Desktop. Look up the clock time (§0).
- Reading the live `~/.local/share/Steam/logs/controller.txt` after a Desktop switch as if it were still the game-mode file. Use `steam-post-0s-*` in the cycle dir.
