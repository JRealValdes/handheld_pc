# Issue: Legion Go 2 suspend / wake stuck

## Symptom

Sometimes the Legion Go 2 appears to suspend (screen off) but does **not** reach a wakeable low-power state: power-button LED stays solid red, heat continues, short power press does nothing. Recovery: long-press hard power-off.

Journal on stuck boots ends at `PM: suspend entry (s2idle)` with **no** `PM: suspend exit`.

Separate from [gyroscope-imu-udev](../gyroscope-imu-udev/).

## Status

**Provisional mitigation + diagnostics** (not a confirmed root-cause fix). Full story in **[KNOWLEDGE.md](KNOWLEDGE.md)**.

Installed hook (`install-hook`):

1. Writes a **pre** dump (state useful if the next attempt sticks).
2. Waits **`SETTLE_MS` (default 1000 ms)** before suspend entry — intentional settle if the bug is a race.
3. Writes a **post** dump on successful resume (missing post ⇒ stuck signature).

## Expected vs buggy

| Step | Healthy | Buggy |
|------|---------|--------|
| Suspend | LED → white blinking | LED stays red; warm |
| Wake | Short press works | No response |
| Journal / hook | `entry`…`exit`; pre+post | `entry` only; pre without post |
| Recovery | n/a | Long-press power |

## Commands

```bash
chmod +x debug-legion-go2-suspend.sh
./debug-legion-go2-suspend.sh install-hook                 # /usr/lib/… + 1s settle
SETTLE_MS=1500 ./debug-legion-go2-suspend.sh install-hook  # stronger settle
./debug-legion-go2-suspend.sh postmortem                   # after stuck + hard-off
./debug-legion-go2-suspend.sh uninstall-hook
```

Dumps: `/var/log/legion-go2-suspend/` and `~/legion-go2-suspend-debug/`.
