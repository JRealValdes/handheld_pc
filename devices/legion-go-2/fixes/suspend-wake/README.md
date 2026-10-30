# Issue: Legion Go 2 suspend / wake stuck

## Symptom

Sometimes the Legion Go 2 appears to suspend (screen off) but does **not** reach a wakeable low-power state: power-button LED stays solid red, heat continues, short power press does nothing. Recovery: long-press hard power-off.

Journal on stuck boots ends at `PM: suspend entry (s2idle)` with **no** `PM: suspend exit`.

Separate from [gyroscope-imu-udev](../gyroscope-imu-udev/).

## Status

Root cause still open. Day-to-day: **no per-suspend debug dumps** (SteamOS updates also wipe `/usr` hooks). Optional **settle-only** hook if you want the 1s race mitigation without I/O. Full story in **[KNOWLEDGE.md](KNOWLEDGE.md)**.

## Expected vs buggy

| Step | Healthy | Buggy |
|------|---------|--------|
| Suspend | LED → white blinking | LED stays red; warm |
| Wake | Short press works | No response |
| Journal | `entry`…`exit` | `entry` only until hard reboot |
| Recovery | n/a | Long-press power |

## Commands

```bash
chmod +x debug-legion-go2-suspend.sh
./debug-legion-go2-suspend.sh status
./debug-legion-go2-suspend.sh install-hook            # settle only (1s, no dumps)
./debug-legion-go2-suspend.sh install-hook --debug    # dumps + settle (when hunting)
./debug-legion-go2-suspend.sh uninstall-hook          # remove hook entirely
./debug-legion-go2-suspend.sh postmortem              # after stuck + hard-off
```

Debug dumps (only with `--debug`): `/var/log/legion-go2-suspend/` and `~/legion-go2-suspend-debug/`.
