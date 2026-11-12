# Legion Go 2 — game pad missing after resume

Durable context for: suspend in **Gaming mode with a game open**, resume succeeds, **the game no longer sees the pad (sticks included)**. Steam UI still works, sticks included. The left Legion button still opens Steam OS.

Distinct from [suspend-wake](../suspend-wake/KNOWLEDGE.md) (machine never finishes s2idle) and from [gyroscope-imu-udev](../gyroscope-imu-udev/KNOWLEDGE.md).

**Status (2026-11-12):** Open. New cluster **15:28** (§3): (1) in-game OK except **right-stick hypersensitive**, (2) second resume → no buttons / H2, (3) freeze on quit game again (dumps truncated mid-write). Philosophy unchanged: diagnose first.

**Scope of truth:** This machine. SteamOS `3.9.5` / `BUILD_ID=20261023.100`, kernel `7.2.7-valve2-2-neptune-72-g31504582a073`, `inputplumber 0.78.0`, DMI `83N0`, USB `17ef:61eb`. User report below is what they have seen several times in Gaming mode.

---

## 0. When the user reports a bad resume (Desktop chat)

**User does almost nothing in-game.** Agreed flow: note clock time + one-line symptom → switch to Desktop → tell the agent here. They should not run `nudge` / `evtest` in Gaming mode.

Symptoms they may report:

- Game pad dead, Steam UI sticks still work → classic H2 path (or partial recovery).
- Steam UI sticks dead too → H1 path.
- Character attacks alone / RB-R1 held → stuck button (§3 01:05). Ask/record whether tapping RB cleared it if they already tried; do not send them back into the game for it.

**Agent checklist (you run these):**

1. Read this file.
2. `systemctl is-active legion-go2-resume-gamepad-trace.service`.
3. Find that resume, not whichever cycle is newest:

```bash
cd "devices/legion-go-2/fixes/resume-gamepad"
./trace-legion-go2-resume-gamepad.sh find "21:40"
```

Replace `21:40` with the time they gave. Match the `resume` line. `LATEST` may be a later suspend, a Desktop session, or a service restart.

4. In that cycle, read in order: `verdict.txt` (if present), `diagnosis.txt`, `nudge.log`, then `summary.txt`, `holders-30s.txt` / `holders-60s.txt`, `post-0s.txt` (look for `event* (deleted)` held by `winedevice`), `post-5s`/`post-15s`, steam tails, journals.
5. Decide with §4 (dead pad) or stuck-button notes in §3. Record back into §3. Prefer classifying H1 vs H2 before proposing more repair. Do not restart InputPlumber or change targets until that cycle is read.
6. Optional live checks on Desktop only if still useful: `./trace-….sh status`, `snapshot`, `nudge` (writes `~/legion-go2-resume-gamepad/manual-nudge/`), or `evtest --query` on the current 360 pad — knowing the game may already be gone and a stuck RB may have cleared.

Switching Gaming → Desktop is **not** a suspend. It does not create a cycle and does not delete old ones (`~/legion-go2-resume-gamepad/cycles/`, last 20, plus `index.txt`). Steam may rotate live `controller.txt` on Desktop; prefer the cycle copies (`steam-post-0s-*`, `steam-post-15s-*`).

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

### 2026-10-30 17:23 → 18:51 — Crimson Desert, Gaming mode (the reported bug)

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261030-172350`. Suspend 17:23:50, resume 18:51:30. Game mode, `gamescope` up, scope `app-steam-app3321460-3877` (**Crimson Desert Enhanced**). User pressed the guide button several times in the first 30s (Steam UI ↔ game).

**Reject H1 for this cycle.** At 18:51:32 Steam logs `Steam controller device opened for index 15` on `/dev/hidraw9`. `post-5s` shows `hidraw9` mode `660`, ACL mask `rw`, and `steam` pid 2414 holding it. No `Unable to open`.

**Config reload happened.** `controller_ui`: `Controller 15 disconnected` at 18:51:29, `connected` at 18:51:32, then `Loaded Config` for app **3321460** (the game), not only for the client UI. Focus returns to the game at 18:51:50, 18:51:54, and 18:52:01, each time reloading that app’s config. Guide events reach the UI (`Guide button sent to JS`).

**The game’s XInput node was replaced and left unopened.**

| | Before suspend (`pre.txt`) | +5s (`post-5s.txt`) |
|--|----------------------------|---------------------|
| Steam virtual pad | `Microsoft X-Box 360 pad 0` (`28de:11ff`) `event17` `js1` `input23` | same name, `event16` `js1` `input32` |
| Who holds it | (fd scan skipped on pre) | **no process** holds `event16` or `js1` |
| Who holds deck hidraw | | `steam` holds `hidraw9` |

`js1` kept the same number; the event node and sysfs id did not. Proton reads this 360 pad, not `hidraw9`. Steam UI reads `hidraw9`. That split matches sticks alive in the Steam UI and dead in the game, including after the overlay was opened and closed.

InputPlumber did recreate the composite device and then logged `Gamepad order: []` after the switch to `deck-uhid`. Steam still opened `hidraw9` and fed the UI, so an empty order did not remove the pad Steam uses.

At 18:52:14 the game-mode Steam client exits (`Exiting workitem thread`). 18:52:23 is a new client on the Desktop config (`413080`). That is the user leaving Game Mode, not a second suspend.

### 2026-10-30 19:16 → 2026-10-31 16:04 — overnight, Gaming mode, Steam UI also dead

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261030-191631`. Suspend 19:16:31, resume 16:04:34 (~21h asleep). Crimson Desert still in scope. User: game dead **and** SteamOS UI did not respond.

**This is H1, not H2.**

| Time | What |
|------|------|
| 16:04:33 | Steam: `Turn off idle controller 15`, `hid_read failure`, PollState → 0. UI: `Controller 15 disconnected`. |
| 16:04:35–36 | InputPlumber rebuilds composite; briefly targets `xbox-elite`, then `deck-uhid`. |
| 16:04:36 | Steam opens **Xbox One Elite 2** as controller **0**, then immediate `hid_read failure` / disconnect. |
| 16:04:37 | Steam finds `Legion Go 2 Controller` on `/dev/hidraw4` → **`Unable to open local device: /dev/hidraw4`**. No later `device opened` for index 15 while still in Game Mode. |
| +5s / +10s | `nudge.log`: **no** `Microsoft X-Box 360 pad 0` (Steam never created it). |
| post-0s / post-5s | `DECK_HIDRAW=hidraw4` mode `000`, ACL mask `---`. Keyboard target `event19` still `660`. |
| 16:06 | User left Game Mode; Steam client restart; hidraw becomes openable; controller 15 connects. |

The Proton `touch` on the 360 pad cannot help: that node never appears when Steam fails the hidraw open. The overnight cycle matches the Desktop 16:20 observation, now confirmed with “Steam UI sticks dead”.

Watcher change after this cycle: repair ACL on `28de:12fb` immediately at resume (+0/+1/+3/+5/+10s) and bounce `deck-uhid` if it had to chmod, so Steam gets a new `Local Device Found` after the node is openable. Still unverified.

### 2026-11-02 01:05 — overnight resume, pad recovered, then stuck RB/R1

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261031-162123`. Suspend 2026-10-31 16:21, resume **01:05:53**. Crimson Desert still running.

**Pad recovery looked healthy (not H1):**

| Time | What |
|------|------|
| 01:05:52 | Steam closes controller 15 (`hid_read failure`). |
| 01:05:55 | Steam opens `/dev/hidraw9` index 15. ACL already `660` / mask `rw`. No `Unable to open`. |
| 01:05:55 | UI loads config for app **3321460**. |
| 01:06:09–10 | Guide → Steam UI → back to game. |
| t+1s… | `nudge.log`: 360 pad `event16` present; touched four times (01:06:15, :17, :45, :50). No ACL fix, no target bounce. |
| ~01:07 (post-15s) | `winedevice.exe` holds `/dev/input/event16`. Game process `CrimsonDesert.e` alive. |

User: controls felt slow to come back, then worked; **a few minutes later** the character attacked continuously as if holding R1/RB. At **01:08:37** Guide → Steam UI again; **01:08:53** Game Mode Steam exits (switch toward Desktop).

**Stuck-button read:**

- Not H1: hidraw was openable and Steam held it.
- Proton attach was delayed: `post-0s` (~01:06:14) had no process on the 360 pad; by `post-5s` (~01:06:45) `winedevice` held `event16`. Matches the slow “controls came back” feeling and the H2 winebus/inotify path.
- Repair touched `event16` **four** times (01:06:15, :17, :45, :50), including after wine already owned the fd.
- No second USB drop or Steam `Unable to open` between 01:06 and 01:08. Next Steam UI activity is Guide at **01:08:37** (user escaping), then Desktop ~01:09.
- Logs do not record which digital button was high; the watcher had no button-state capture yet.
- Best fit: Steam Input / Proton **latched a digital button** (RB/R1) across the XInput reattach and/or the 01:06:09–10 overlay↔game focus flip — not a dead pad.
- **User (2026-11-02):** stuck RB also happened **before** this watcher existed. That demotes the multi-`touch` theory from cause to optional aggravator. Root is likely in the stock resume path (Steam Input / Proton / game), not introduced by the hook. Repair still touches the 360 pad **once** per cycle (enough for H2; no need to repeat).

**If it happens again:** note whether tapping RB once clears it (classic latch) or it stays down with no physical press (synthetic hold). Capture `EVIOCGKEY` / `evtest --query` on the 360 pad while stuck.

### 2026-11-02 21:31 — soft fail (game dead, Steam UI OK) = H2

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261102-190025`. Suspend 19:00, resume **21:31:24**. App was **3321460**, then UI activity toward **2767030**.

| Time | What |
|------|------|
| 21:31:23 | Steam closes controller 15 (`hid_read failure`). |
| 21:31:26 | Steam opens `/dev/hidraw9` index 15. ACL already openable. No `Unable to open`. |
| t+0…t+5 | `nudge.log`: hidraw OK; **no** `Microsoft X-Box 360 pad 0` yet. `fixed_acl=0 bounced=0`. |
| t+10 (~21:32:28) | 360 pad `event16` appears; **one** `touch`. |
| post-15s | `event16` exists; **no** process holds it (`winedevice` absent on that node). Steam holds `hidraw9`. |

**Read:** Classic H2. UI works because Steam reopened deck-uhid. Game stays dead because Proton never opened the recreated XInput pad. Our single `touch` ran but did not produce an attach by ~15s. We did not seal anything or bounce targets.

### 2026-11-02 21:49 — hard fail (Steam UI sticks dead) = H1 + late USB

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261102-213641` (incomplete: only `nudge` t+0 + `post-0s`; no summary). Suspend 21:36, resume **21:49:44**. Game **2767030** / `Marvel.exe` still in session.

| Time | What |
|------|------|
| 21:49:43 | Steam closes controller 15. |
| t+0 / post-0s | **No** USB `17ef:61eb`, **no** `hid-lenovo-go`, **no** uhid `28de:12fb`, InputPlumber **0** composite devices. Repair: no 360 pad; no deck hidraw to chmod. |
| 21:49:46–47 | (seen in a later cycle’s Steam copy) `Local Device Found` `/dev/hidraw4` → **`Unable to open`** twice. |
| 21:50:33 | Steam finally opens index 15. |
| Cycle | Delayed repairs / post-5s / post-15s **never written** (power hold or hang during the window). |

**Read:** Hard fail is stock H1 after a slow USB reappear, not a bounce/chmod side effect (`fixed_acl=0 bounced=0`). Gap: t+0 is too early when USB is still missing; if later repair ticks are killed, we never chmod the sealed hidraw Steam already failed to open.

**Watcher change after 21:31/21:49:** repair loop is **wall-clock** (t+0 then 1,2,3,5,8,12,20,30,45,60s) in its own background job, not chained behind `write_snapshot`. Bounce once after chmod, or once if deck hidraw is openable but Steam still holds nothing after ≥3s and no 360 pad yet. XInput `touch` up to **twice** while `winedevice` has no fd.

### 2026-11-08 22:08 — soft fail again (H2), dual touch did not attach

Cycle `~/legion-go2-resume-gamepad/cycles/cycle-20261108-213020`. Suspend 21:30, resume **22:08:01**. App **3321460**. User: game pad dead, Steam UI OK.

| Time | What |
|------|------|
| 22:08:01 | Steam closes controller 15. |
| 22:08:04 | Steam opens `/dev/hidraw4` index 15. ACL openable. No `Unable to open`. |
| post-0s | **`winedevice` holds `/dev/input/event16 (deleted)`** (stale pre-suspend XInput fd). |
| t+0…t+12 | No 360 pad yet in `nudge.log`. `fixed_acl=0 bounced=0`. |
| ~post-5s | New `Microsoft X-Box 360 pad 0` on `event16` exists; Steam holds `hidraw4`; **no** live wine hold on the new node. |
| t+20 / t+30 | Two `touch`es on `event16`. |
| t+45 / t+60 | Still no wine live hold; skip further touches. |
| 22:08:15–52 | Repeated Guide overlay ↔ game (user trying to recover). |

**Read:** Confirmed **H2**. Smoking gun is wine’s **deleted** `event16` at post-0s while Steam UI path recovered. Repair touches ran and still no attach by 60s — do **not** escalate hammer yet; add diagnosis artifacts (`verdict.txt`, late holders dumps) so the next report classifies in one file.

**Watcher change after 22:08 (diagnose-first):** each repair tick appends `diagnosis.txt` and updates `verdict.txt` (`H1_NO_DECK` / `H1_SEALED` / `H2_WINE_STALE_DELETED` / `H2_PAD_ABSENT` / `H2_PAD_UNHELD` / `OK_WINE_ATTACHED` / `TRANSITIONAL`). Late `holders-30s.txt` / `holders-60s.txt`. Summary leads with verdict. Fix `proc_holds_node` races. No new repair actions.

### 2026-11-11 17:56–17:58 — hard then soft, then freeze on game exit

Two cycles back-to-back; then forced power (service came back `ExecMainStartTimestamp=17:59:51`).

#### Resume 1 — 17:56:44 (`cycle-20261111-150839`)

User: mandos + Steam UI dead.

| Evidence | Note |
|----------|------|
| `diagnosis` t+0 | `H1_NO_DECK` |
| t+1… | deck `hidraw4` openable; `steam_holds_deck=0` in diagnosis for the whole cycle |
| t+2… | 360 pad present; two touches; verdict stays `H2_PAD_UNHELD` |
| `steam-post-0s` | Only `hid_read failure` / PollState 0 at 17:56:44 — **no** `device opened` in that immediate tail |
| `post-0s` (slow dump) | Later shows `steam` holding `hidraw4` **and** `winedevice` holding live `event16` (+ a deleted hidraw0) — snapshot lag / mid-recovery |
| t+45 | `H1_NO_DECK` again — **overlaps** second suspend at 17:57:25 |
| Steam reopen in logs | First clear `opened for index 15` in this cycle’s later tails is **17:57:35** (second resume) |

**Read:** Matches a bad/slow Steam UI path on first wake (no open in the early Steam tail). Not a sealed-ACL H1 (`mode=660`). Final `verdict=H2_PAD_UNHELD` is partly polluted by the overlapping second suspend and by diagnosis missing steam’s hold that `post-0s` eventually saw.

#### Resume 2 — 17:57:33 (`cycle-20261111-175725`)

User: Steam UI OK, game dead.

| Evidence | Note |
|----------|------|
| 17:57:35 | Steam opens `/dev/hidraw10` index 15 |
| `post-5s` / `post-15s` | `steam` holds `hidraw10`; **no** `winedevice` on `event16` |
| `verdict` | `H2_PAD_UNHELD` through 60s; two touches, no attach |

**Read:** Clean **H2** (UI path up, Proton not on the new XInput pad). Same nail as 22:08 / 21:31.

#### Freeze on leaving the game (new)

No watcher cycle: force power-off kills logging. Journal around resume shows Decky `PluginLoader` / **Panel de Control** (`resume_detected`, TDP/CPU/fan reapply). Plugin dir mtime **2026-11-11 14:43**, flags `root`. **No proof** it caused the hang; worth an A/B (disable plugin) if freezes repeat. Distinct from H1/H2 pad loss.

#### Diagnosis gaps found this incident

- `holders-30s.txt` / `holders-60s.txt` listed **no** open fds while `post-15s` showed `steam → hidraw10` — holders scanner bug; fixed to match `write_snapshot` style.
- Back-to-back suspends interleave two repair loops; read **both** cycles when the user reports a cluster.

### 2026-11-12 15:28 — hypersensitive RS → dead pad → freeze on quit

Cycles `cycle-20261112-140658` (resume **15:28:05**) then `cycle-20261112-152850` (suspend 15:28:50 / resume **15:28:57**). Force power ~15:29 (service restart 15:30:18). App **3321460**.

#### Resume A — 15:28:05 (user: all OK except right stick “muy muy” sensitive)

| Evidence | Note |
|----------|------|
| 15:28:07 | Steam opens **Xbox One Elite 2** as controller **0** (`45e:b00`, `uses xinput : false`) — InputPlumber’s brief `xbox-elite` target |
| 15:28:08 / :10 | Steam opens Legion `28de:12fb` index **15** (twice) |
| `post-0s` | `steam` → `hidraw4`; **`winedevice` has four fds on live `event16`** (Microsoft X-Box 360 pad 0) |
| `post-5s` | Same wine pid still has **four** `event16 (deleted)` fds; new 360 pad exists; steam on `hidraw4` |
| `post-15s` | steam on `hidraw4`; no wine lines in the open-fd filter |
| `diagnosis` | Final `H2_PAD_UNHELD`; never reported `wine_holds_deleted=1` despite post-5s — detector gap |
| Late files | `holders-*`, journals, `summary`, steam-post-15s/60s are **0-byte** (second cycle / power cut ate the late writer) |

**Read:** Not “dead pad”. Game had input. Hypotheses for RS hypersensitivity (unproven): (a) **multiple wine fds** on the same XInput node amplifying axes; (b) brief **Elite 2 + Legion** dual-controller / wrong config; (c) Steam Input + Proton both driving look. Need axis/fd-count in diagnosis next time.

#### Resume B — 15:28:57 (user: no buttons; Steam UI OK → quit → freeze)

| Evidence | Note |
|----------|------|
| `verdict` / diagnosis | `H2_PAD_UNHELD` through the ticks that finished |
| Dumps | `post-0s` truncated with **NUL padding**; `post-5s`/`post-15s` empty; `nudge.log` cut mid-line — **power cut while writing** |
| Freeze | Same new symptom as 2026-11-11 (hang on leaving game / force power). Still no stack trace. Decky Panel de Control remains chronological suspect only. |

**Read:** Classic soft H2 after the second resume, then hang outside our pad path.

---

## 4. Hypotheses (ranked for the Gaming-mode report)

### H2 — Running game does not open the recreated XInput pad (supported by 18:51)

**What:** Suspend destroys `Microsoft X-Box 360 pad 0` (Steam’s XInput evdev, `28de:11ff`). Resume creates a new one. Steam reopens `hidraw` `28de:12fb`, reloads the game’s controller config, and the Steam UI works. The already-running game never opens the new `event*` / `js*` node.

**18:51 result:** Supported. Config reload for app 3321460 happened, `hidraw9` was openable and held by `steam`, and no process held the new 360 pad (`event16` `js1`). Opening the overlay and returning to the game did not attach it. Quitting and relaunching the game does (user, other incidents). “Config never reloaded” is the branch this cycle rules out.

**Why the running game stays detached:** Crimson Desert is Proton 11. Proton’s `winebus` inside the pressure-vessel container does not trust udevd; it watches `/dev/input` with inotify (`IN_CREATE` + `IN_ATTRIB`). On create it `open()`s the new `event*` node. If that open fails because the node is not readable yet, it waits for a later attribute change and tries again. If that attribute event is missed, wine never opens the recreated `Microsoft X-Box 360 pad 0`. A new process enumerates `/dev/input` from scratch, which is why relaunch works and the overlay does not.

The watcher `touch`es that 360-pad node after resume (`IN_ATTRIB` for winebus). Useful only when Steam already opened deck-uhid (H2). Unverified as a full fix.

### H1 — Steam cannot open deck-uhid hidraw (confirmed 16:04 overnight + Desktop 16:20)

**What:** USB drop closes controller 15. InputPlumber recreates `28de:12fb`, but `/dev/hidraw*` stays mode `000` / ACL mask `---`. Steam logs `Unable to open` and does not retry. No `Microsoft X-Box 360 pad 0`. Steam UI sticks and the game are both dead. The InputPlumber Keyboard target can still be openable (Legion/guide may still reach gamescope even when sticks do not).

**Where confirmed:** Desktop 2026-10-30 16:20; Gaming overnight 2026-10-31 16:04 (`Unable to open /dev/hidraw4`, nudge saw no 360 pad).

**Auto attempt:** chmod/setfacl the sealed hidraw as soon as it appears, then briefly set targets to `keyboard mouse` and back to `deck-uhid keyboard mouse` so Steam rediscovers an openable node. Not yet proven.

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
