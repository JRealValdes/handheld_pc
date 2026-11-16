# Fix: Legion Go 2 gyroscope

## Symptom

Gyro does nothing in Steam Input / games on Lenovo Legion Go 2 (SteamOS), even though InputPlumber is running.

## What this folder is

Knowledge + automation for Legion Go 2 gyro on SteamOS. Failures can have more than one cause; see **[KNOWLEDGE.md](KNOWLEDGE.md)** for architecture and documented cases.

## Current script coverage

`fix-legion-go2-gyro.sh` currently addresses **Case A** only: stock udev never enables handle IMUs (wrong sysfs names / missing `imu_enabled`). A Windows boot can clear the flags the controller had remembered; without this overlay, a SteamOS reboot does not turn them back on. Secure Boot and boot order are unrelated. The script waits briefly for the controller to confirm the write. It is expected to grow as more cases are documented.

## Apply

```bash
chmod +x ./fix-legion-go2-gyro.sh
./fix-legion-go2-gyro.sh
```

Asks for admin password (`pkexec`). Idempotent — safe after SteamOS updates.

On failure, writes `~/Downloads/legion-go2-gyro-debug-<UTC>.txt`.

## System overlay created (Case A)

`/etc/udev/rules.d/99-legion-go2-imu-fix.rules`
