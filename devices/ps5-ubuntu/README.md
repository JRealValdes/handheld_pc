# PS5 + Ubuntu

Ubuntu gaming stack with **DualSense** (PlayStation 5 controller), typically over Bluetooth + Steam.

## Fixes

| Fix | Summary |
|-----|---------|
| [dualsense-bt-disconnect](fixes/dualsense-bt-disconnect/) | DualSense drops a few seconds into a game (Marvel Rivals). Workaround: Steam PlayStation Controller Support **Disabled** |

## Scope notes

- Device folder name matches how we refer to this machine in chat (`ps5-ubuntu`).
- Prefer diagnosing BlueZ / kernel HID / Steam Input before changing system packages.
