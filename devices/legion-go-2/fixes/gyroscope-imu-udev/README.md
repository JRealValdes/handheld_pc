# Fix: Legion Go 2 gyroscope (IMU udev)

## Symptom

Gyro does nothing in Steam Input / games on Lenovo Legion Go 2 (SteamOS), even though InputPlumber is running.

## Cause (one line)

Controller IMU stays **off** because stock SteamOS udev uses wrong sysfs attribute names and never sets `imu_enabled`.

## Apply

```bash
chmod +x ./fix-legion-go2-gyro.sh
./fix-legion-go2-gyro.sh
```

Asks for admin password (`pkexec`). Idempotent — safe after SteamOS updates.

On failure, writes `~/Downloads/legion-go2-gyro-debug-<UTC>.txt`.

## Durable knowledge

See **[KNOWLEDGE.md](KNOWLEDGE.md)** for architecture, verification checklist, and anti-patterns.

## System overlay created

`/etc/udev/rules.d/99-legion-go2-imu-fix.rules`
