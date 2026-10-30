# Legion Go 2 — Suspend / wake stuck

Durable context for an intermittent SteamOS s2idle failure on the Legion Go 2. Distinct from gyro ([gyroscope-imu-udev](../gyroscope-imu-udev/KNOWLEDGE.md)).

**Status (2026-10-30):** Open root cause. **Per-suspend debug dumps are off** on this machine (hook under `/usr` was wiped by a SteamOS update; not reinstalled with dumps). Script default is now **settle-only** if reinstalled; use `install-hook --debug` only when hunting a recurrence.

**Scope of truth:** User-observed behavior + on-device journal/dumps. Revise when diagnosis advances.

---

## 0. Current deployed state (what is on the machine)

| Piece | Role | On device now? |
|-------|------|----------------|
| systemd-sleep hook under `/usr/lib/systemd/system-sleep/` | Optional | **Absent** after OS update (2026-10); `steamos-readonly` enabled again |
| Settle `SETTLE_MS` (default 1000 ms) | Provisional race mitigation | Not running until `install-hook` |
| Pre/post dumps + trail | Evidence if stuck returns | **Off** (default). Enable with `install-hook --debug` |
| `./debug-legion-go2-suspend.sh postmortem` | After hard power-off | Available anytime (on-demand) |

**Intentional design (script):**

1. **Default `install-hook`:** sleep `SETTLE_MS` only — no `find`, no journal scrapes, no dump files.
2. **`install-hook --debug`:** dump first (racy pre-state), then settle; post dump on resume.
3. SteamOS `systemd-sleep` only runs `/usr/lib/systemd/system-sleep/` (not `/etc`). Updates remount/replace `/usr` and **drop custom hooks** — reinstall after major updates if you still want settle.

**What this is not:** not an EC quirk, not a gyro/InputPlumber change, not a confirmed firmware fix. Quiet stretches without the hook also happen; do not treat absence of dumps as proof the race theory is wrong or right.

---

## 1. Problem statement

Intermittent failure around system suspend. UI looks like sleep (display blanks), but the device never reaches a proper low-power / wakeable state. Short power press does nothing; recovery is long-press hard power-off.

### Healthy flow

1. Suspend via Steam power menu **or** short power-button press.
2. Display off; LED **red → white blinking**.
3. Short press wakes; LED → solid red.

### Buggy flow

1. Same trigger; display off.
2. LED stays **solid red**; unit stays warm.
3. Short press does nothing.
4. Only long-press forced shutdown recovers.

---

## 2. Observable signals

| Signal | Healthy | Stuck |
|--------|---------|-------|
| Display | Off | Off (misleading) |
| Power LED | White blinking | Solid red |
| Heat | Cools | Still warm |
| Short power press | Wakes | No effect |
| Journal | `PM: suspend entry` … later `exit` | `entry` then **no** `exit` until next boot |
| Hook trail | `pre` then `post` | `pre` only |

LED is the fastest user check.

---

## 3. Environment snapshot (observed 2026-08-04)

| Item | Value |
|------|-------|
| SteamOS | `VERSION_ID=3.8.16`, `BUILD_ID=20260716.1` |
| Kernel | `6.16.12-valve24.5-1-neptune-616-gb2f7cfe85e45` |
| Suspend path | **s2idle only** (`/sys/power/mem_sleep` → `[s2idle]`) |
| ACPI | **S0 S4 S5** (no classic S3) |
| Valve quirk | `Using s2idle quirk to avoid Lenovo Legion Go 2 platform firmware bug` |

---

## 4. Journal signature (confirmed)

Healthy and stuck look identical through freeze + entry:

1. Power key / menu → `The system will suspend now!`
2. NetworkManager sleep / wlan unmanaged
3. `Successfully froze unit 'user.slice'`
4. (hook) pre dump ± settle
5. `PM: suspend entry (s2idle)`

**Healthy:** later `PM: suspend exit`.  
**Stuck:** boot journal **ends** at entry; next boot is cold start after hard-off.

This is not “Steam only blanked the panel.” Userspace reaches real suspend entry; s2idle / wake / EC leaves the unit unwakeable (red LED + heat).

---

## 5. Hypotheses (ranked, none confirmed)

### H1 — Settle / race before s2idle (leading working theory)

**What:** Entering s2idle while the platform is still settling (USB Legion controller re-enumerate, InputPlumber rebind, GPU/SMU resume, heavy game start) leaves firmware/EC or wake path in a bad state: OS thinks it suspended; LED never blinks white; short press cannot wake.

**Why it fits:**

- Intermittent on the same kernel/build (many OK cycles, rare stuck).
- Incidents clustered around “dirty” moments: ~30s after wake with `17ef:61eb` reconnect + Shadows loading; or first suspend ~90s after reboot with Shadows just launched.
- Same path works repeatedly when the machine has been idle/stable.
- Valve already ships an s2idle quirk for this platform → firmware sleep is known-fragile.
- Accidental long pre-hook work (`find /sys/...`) *might* have reduced rate by delaying entry — unproven; hence we now use an **explicit** `SETTLE_MS` instead of relying on slow dumps.

**Why not proven:** Stuck still happened once with a dump-only pre-hook; no A/B with settle vs no settle yet; no kernel/EC smoking gun line unique to stuck boots.

### H2 — s2idle “success” without real low power / EC sync

**What:** Kernel reaches `suspend entry` but EC/LED/power rails never enter the white-blink sleep state; SoC stays partially active (heat).

**Why:** Matches LED + heat while userspace is frozen. Overlaps H1 (race could cause this).

### H3 — Wake IRQ / power-button path dead after bad entry

**What:** Entry somehow succeeds; resume never starts on short press.

**Why:** Matches “no wake until hard-off.” Hard to separate from H2 without more PM debug.

### H4 — Residual firmware bug despite Valve quirk

**What:** Quirk incomplete or conditional; still hit on some sequences.

**Why:** Quirk present on both good and bad boots — not a discriminator by itself.

### H5 — Ruled out / very unlikely

- **Compositor-only blank:** contradicted by `PM: suspend entry` on stuck boots.
- **Gyro / IMU udev overlay:** no evidence; separate stack; do not “fix” gyro for this.
- **logind inhibitors blocking sleep:** stuck pre-dumps showed `No inhibitors`.
- **“Debug hook alone fixed it”:** 21:44 failure already had pre-hook dumps; quiet days ≠ proof.

---

## 6. Documented incidents

### 2026-08-04 ~20:05 — after AC Shadows + quick re-suspend

- Boot `2c80abc6…`. Healthy sleep `19:57→20:05`, then USB controller disconnect/reconnect, InputPlumber errors/re-add, Shadows (`3159330`) resuming.
- ~32s later: power → entry `20:05:39` → no exit → hard-off.
- Hook was still wrongly under `/etc` then → **no pre dump**.

### 2026-08-04 ~21:44 — first suspend after reboot (pre-hook captured)

- Prior boot: many OK rapid suspends **with** Shadows + working pre/post hooks; clean reboot.
- New boot `89e415a3…`: Shadows `21:42:59`; first suspend `21:44:05` → pre dump written → entry → **no post** → hard-off.
- Pre ≈ last good pre (no inhibitors). Wake-source section empty (hook bug; class nodes lack `enable` — later fixed).
- Takeaway: not “every Shadows suspend fails”; stuck as **first** suspend after reboot while game coming up.

Artifacts under `~/legion-go2-suspend-debug/` and `/var/log/legion-go2-suspend/`.

### 2026-08-07 — quiet stretch

- Several days without recurrence after enriched dumps (and before explicit `SETTLE_MS`).
- Recorded as **possible** rate drop from added latency; **not** accepted as root-cause fix. Explicit settle added so mitigation is intentional and tunable.

---

## 7. Tooling / ops

```bash
cd devices/legion-go-2/fixes/suspend-wake
./debug-legion-go2-suspend.sh status
./debug-legion-go2-suspend.sh install-hook            # settle only (default)
./debug-legion-go2-suspend.sh install-hook --debug    # dumps + settle
SETTLE_MS=1500 ./debug-legion-go2-suspend.sh install-hook
./debug-legion-go2-suspend.sh postmortem              # after stuck + hard-off
./debug-legion-go2-suspend.sh uninstall-hook
```

**If it fails again:**

1. Note LED (red vs white blink), game, charging, dock, seconds since last wake/boot.
2. Hard power-off → boot → `./debug-legion-go2-suspend.sh postmortem`.
3. Keep `pre-suspend-*` (no matching `post`), `hook-trail.log`, journal boot that ends at `suspend entry`.
4. Check journal for `legion-go2-suspend` (`settle …` / `settle done`) — confirms settle ran before entry.

**A/B idea (later):** `SETTLE_MS=0` reinstall vs `1000` to see if stucks return — only way to strengthen H1.

---

## 8. Anti-patterns

- Blank screen alone ≠ successful suspend.
- Blaming gyro/InputPlumber/IMU udev without evidence.
- Shipping EC quirks or custom InputPlumber binaries for this without journal proof.
- Installing hooks only under `/etc/systemd/system-sleep/` on SteamOS (ignored).
- Declaring the bug “fixed” because it went quiet.
- Expecting SSH while stuck (wlan asleep, user.slice frozen).

---

## 9. Confirmed root-cause cases

*(None yet. Provisional settle is mitigation-under-hypothesis, not a closed case.)*
