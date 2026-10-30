# Lenovo Legion Go 2

SteamOS handheld (DMI product `{83N0,83N1}`). Input stack: **InputPlumber** + **hid-lenovo-go** + **steamos-manager**.

## Fixes

| Fix | Summary |
|-----|---------|
| [gyroscope-imu-udev](fixes/gyroscope-imu-udev/) | Gyro knowledge + fixes; script currently covers Case A (stock udev IMU attrs) |
| [suspend-wake](fixes/suspend-wake/) | Open: s2idle stuck — provisional settle + debug dumps (see KNOWLEDGE) |

## Official stack notes

- Package: `inputplumber` → `/usr/bin/inputplumber`
- Device profile: `/usr/share/inputplumber/devices/50-legion_go_2.yaml`
- Targets (steamos-manager): `deck-uhid`, `keyboard`, `mouse`  
  → `/usr/share/steamos-manager/devices/legion-go-series.toml`
- Controller USB PID (XInput attached): `17ef:61eb`
