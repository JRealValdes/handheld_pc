# Issue: Legion Go 2 suspend / wake stuck

## Symptom

Sometimes the Legion Go 2 appears to suspend (screen off) but does **not** enter real sleep: power-button LED stays solid red, the unit keeps producing heat, and a short power-button press does not wake it. Only a long-press forced power-off recovers the device.

This is **separate** from the [gyroscope-imu-udev](../gyroscope-imu-udev/) issue.

## Status

Open investigation — no fix script yet. Document symptoms and collect evidence in **[KNOWLEDGE.md](KNOWLEDGE.md)**.

## Expected vs buggy behavior

| Step | Healthy | Buggy |
|------|---------|--------|
| Enter suspend (power menu or short power press) | Screen off; LED red → white blinking | Screen off; LED stays red; device still warm |
| Wake (short power press) | Screen on; LED → red | No response; still red LED |
| Recovery | n/a | Long-press power → forced off |

## Next

Capture logs / sleep state around a failed suspend (see KNOWLEDGE § Diagnostics). Do not invent overlays until a root cause is confirmed.
