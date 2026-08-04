# Legion Go 2 — Suspend / wake stuck

Durable context for a SteamOS suspend regression on the Legion Go 2. Distinct from gyro ([gyroscope-imu-udev](../gyroscope-imu-udev/KNOWLEDGE.md)).

**Status:** Open — symptoms reported; root cause unknown. Started after a SteamOS (or related stack) update; previously reliable.

**Scope of truth:** User-observed behavior only until reproduced with logs. Revise this file when diagnosis advances.

---

## 1. Problem statement

Intermittent failure to enter real system suspend. The UI path looks like sleep (display blanks), but hardware indicators show the machine never reached a proper low-power state. Wake via short power-button press then does nothing; recovery requires holding the power button until hard power-off.

### Healthy flow

1. Suspend via Steam power menu **or** short press on the power button.
2. Display turns off.
3. Power-button LED changes from **solid red** → **white blinking** (true sleep indicator on this device).
4. Short press on power button wakes the device.
5. LED returns to **solid red**; display comes back.

### Buggy flow

1. Same suspend trigger (power menu or short power press).
2. Display turns off — looks like sleep from the UI.
3. Power-button LED remains **solid red** (never white blinking).
4. Device continues to generate heat (CPU/SoC still active or not fully gated).
5. Short power press does nothing — no wake, LED still red.
6. Only recovery: long-press power button → forced shutdown, then normal boot.

---

## 2. Observable signals (device-specific)

Use these as the primary “are we really asleep?” check on Legion Go 2:

| Signal | Healthy suspend | Stuck / fake suspend |
|--------|-----------------|----------------------|
| Display | Off | Off (misleading) |
| Power LED | White blinking | Stays solid red |
| Heat / fans | Cools / quiet | Still warm / active |
| Short power press | Wakes | No effect |
| Recovery | Soft wake | Hard power-off only |

The **LED color** is the fastest user-visible discriminator: if it never goes white-blinking after a suspend attempt, treat the session as the buggy case even before trying to wake.

---

## 3. Triggers / notes from reports

- Reproduced via **Steam power menu → Suspend** and via **short power-button press**.
- Intermittent (not every suspend).
- Regression after an update (exact SteamOS / kernel / firmware version TBD — fill in when known).
- Not believed related to the gyro/IMU udev overlay; do not conflate diagnostics.

---

## 4. Working hypotheses (unconfirmed)

Do not treat these as root cause. Useful starting points for logs:

1. **Suspend abort / failed transition** — userspace requests sleep; kernel or a wake source aborts; display blanked by compositor but system stays in S0 / “freeze” half-state.
2. **Power-button / ACPI event mishandled** — button event consumed while stuck; subsequent short presses ignored until hard reset.
3. **Firmware / EC LED vs OS sleep desync** — less likely if heat persists (that implies OS/SoC still active).
4. **SteamOS / Gamescope / steamos-manager regression** post-update — sleep path changed; need journal around suspend attempt.

---

## 5. Diagnostics to capture (when it happens next)

Prefer capturing **during or immediately after** a failed suspend (before hard power-off if possible via SSH from another machine). If SSH is unavailable, note SteamOS build and reproduce with logging enabled on a later attempt.

Checklist ideas (refine once tooling exists):

```text
- SteamOS version / build (steamos-version, uname -r)
- journalctl from ~2 min before suspend attempt through hard recovery
  Focus: suspend, resume, power button, ACPI, Gamescope, steam
- /sys/power/state and last sleep transition messages
- Whether wake sources or inhibitors blocked sleep
- Power LED state observed (red vs white blinking) — always record
```

A future `debug-legion-go2-suspend.sh` (or similar) can dump this; do not invent a “fix” overlay until a cause is confirmed.

---

## 6. Anti-patterns

- Treating blank screen alone as proof of successful suspend (LED + heat matter).
- Blaming or “fixing” gyro / InputPlumber / IMU udev for this symptom without evidence.
- Shipping speculative systemd oneshots or EC quirks before journal proof.
- Assuming every failed wake is the same bug — document variants if LED *does* blink but wake still fails.

---

## 7. Documented failure cases

Add a subsection when a root cause is confirmed.

*(None yet.)*
