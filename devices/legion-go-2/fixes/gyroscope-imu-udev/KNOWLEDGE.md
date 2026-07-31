# Legion Go 2 — Gyroscope knowledge base

Durable context for SteamOS + InputPlumber. Recover from this file after any update or AI session reset.

**Verified on:** SteamOS 3.8.16 · kernel `6.16.12-valve24.5-1-neptune-616` · `inputplumber` 0.77.4–0.78.0 · handle FW `260310a` · USB `17ef:61eb`

---

## 1. What must be true for gyro to work

```text
Hardware IMU in controllers (handles)
        ↓
hid-lenovo-go: imu_enabled=true AND imu_bypass_enabled=true  (BOTH handles)
        ↓
HID XInput reports carry non-zero gyro/accel fields
        ↓
InputPlumber stock (/usr/bin/inputplumber) reads hidraw → Gyroscope:Left/Right/Center
        ↓
steamos-manager target includes deck-uhid (or deck / dualsense)
        ↓
Steam Input gyro binding in the game
```

**Single persistent system change we own:**

`/etc/udev/rules.d/99-legion-go2-imu-fix.rules`

Everything else should stay stock.

---

## 2. Root cause (the real one)

### Not the IIO buffer

Earlier investigation focused on AMD SFH `gyro_3d` and `buffer/enable → Invalid argument`.

- Screen gyro exists: AMD SFH (`pcie_mp2_amd`) → `HID-SENSOR-200076` → IIO `gyro_3d`.
- InputPlumber **does not use the IIO buffer**. It polls `*_raw` via libiio.
- Buffer failure is a real quirk, but **irrelevant** to Steam Input gyro on Go 2.

### Actual chain

1. **Controller IMU off**  
   `imu_enabled=false` / `imu_bypass_enabled` not `true` under  
   `/sys/bus/hid/drivers/hid-lenovo-go/*/…/{left,right}_handle/`.

2. **Broken stock udev**  
   `/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules` writes:
   - `left_handle/imu_bypass_enable` ← **missing final `d`**
   - never sets `imu_enabled`  
   Real attrs: `imu_enabled`, `imu_bypass_enabled`.

3. **InputPlumber design**  
   When module `hid_lenovo_go` is loaded, stock IP **filters out** center IIO (screen) gyro, assuming handle IMUs work. If handles are off → **zero gyro total**.

---

## 3. Architecture cheat sheet

| Path | Role on Go 2 |
|------|----------------|
| USB `17ef:61eb` iface 2 + `hid-lenovo-go` | **Primary** gyro/accel (handles) |
| AMD SFH IIO `gyro_3d` | Screen/tablet gyro; filtered by stock IP when `hid_lenovo_go` loaded |
| InputPlumber | Composite device; polls handle HID + optional IIO |
| steamos-manager `legion-go-series.toml` | Sets targets `deck-uhid`, `keyboard`, `mouse` |
| Steam Input | Consumes virtual Deck controller motion |

### Sysfs (handles)

```text
/sys/bus/hid/drivers/hid-lenovo-go/<id>/left_handle/imu_enabled
/sys/bus/hid/drivers/hid-lenovo-go/<id>/left_handle/imu_bypass_enabled
/sys/bus/hid/drivers/hid-lenovo-go/<id>/right_handle/imu_enabled
/sys/bus/hid/drivers/hid-lenovo-go/<id>/right_handle/imu_bypass_enabled
```

Expected after fix: all four = `true`.

### IIO (optional signal)

- `iio:device0` is often **ALS**, not gyro — always check `name`.
- Gyro name: `gyro_3d`. Raw `in_anglvel_{x,y,z}_raw` can change when polled; still not the Steam path when handles work.

---

## 4. Apply / re-apply after SteamOS update

```bash
cd "devices/legion-go-2/fixes/gyroscope-imu-udev"
./fix-legion-go2-gyro.sh
```

Script scope (only):

1. Write `/etc/udev/rules.d/99-legion-go2-imu-fix.rules`
2. `udevadm control --reload` + trigger
3. Write `true` to the four IMU attrs
4. `systemctl restart inputplumber`
5. Verify attrs + soft-check capabilities/targets

On failure → `~/Downloads/legion-go2-gyro-debug-<UTC>.txt`

**Does not:** install custom IP binaries, change profiles, force `deck` vs `deck-uhid`, clean home directories.

---

## 5. Verification checklist (step by step)

Run on the Legion Go 2 (Desktop mode is fine).

### A. IMU attrs

```bash
for d in /sys/bus/hid/drivers/hid-lenovo-go/*/left_handle \
         /sys/bus/hid/drivers/hid-lenovo-go/*/right_handle; do
  echo "$d: enabled=$(cat "$d/imu_enabled") bypass=$(cat "$d/imu_bypass_enabled")"
done
```

Expect: `enabled=true bypass=true` for both.

### B. Our udev overlay exists

```bash
cat /etc/udev/rules.d/99-legion-go2-imu-fix.rules
```

Must mention `imu_enabled` and `imu_bypass_enabled` (with **d**).

### C. Stock udev still wrong (why overlay is needed)

```bash
grep imu_bypass /usr/lib/udev/rules.d/99-inputplumber-device-setup.rules
```

Expect stock line still says `imu_bypass_enable` (no `d`) until Valve fixes it.

### D. InputPlumber process

```bash
systemctl is-active inputplumber
readlink -f /proc/$(systemctl show -p MainPID --value inputplumber)/exe
```

Expect: `active` and `/usr/bin/inputplumber` (not a custom path under `~/Applications`).

### E. Targets (official)

```bash
inputplumber device 0 targets list
```

Expect something gyro-capable, typically **`deck-uhid`** (steamos-manager). `deck` also OK. `xbox-elite` alone → no gyro path to Steam.

### F. Capabilities

```bash
inputplumber device 0 capabilities | tr ',' '\n' | grep -i Gyro
```

Expect: `Gyroscope:Left`, `Gyroscope:Right`, `Gyroscope:Center` (names may vary slightly).

### G. In-game

Game Mode → Steam Input → enable gyro on the Deck/Steam Controller style profile. Physical tilt should move aim/camera.

---

## 6. Anti-patterns (do not repeat)

| Mistake | Why it hurts |
|---------|----------------|
| Custom InputPlumber with `GYRO_GAIN=50` | Handle values are already i16-scale; ×50 saturates → jumpy gyro |
| systemd override to a home-built IP binary | Breaks on updates; hides stock fixes |
| Forcing `deck` via oneshot while fighting manager | steamos-manager already sets `deck-uhid` (has gyro) |
| Chasing IIO `buffer/enable` as the Steam blocker | IP does not use that buffer |
| Assuming `iio:device0` is always gyro | Often ALS; read `name` |
| Enabling IIO screen gyro *and* handle gyros with huge gain | Double path + bad scale → chaos |
| Editing `/usr/share/inputplumber/...` only | SteamOS updates overwrite `/usr`; prefer `/etc` overlays or udev |

---

## 7. Healthy vs broken snapshot

### Healthy

- Four IMU attrs `true`
- Overlay udev present
- `/usr/bin/inputplumber` running
- Targets include `deck-uhid` (or `deck` / DualSense)
- Capabilities include `Gyroscope:*`
- No `ExecStart=` override under `/etc/systemd/system/inputplumber.service.d/`

### Broken (common)

- Attrs `false` / `unknown` after update that restored only stock udev
- Custom binary / `GYRO_GAIN` override left behind
- Only `xbox-elite` target and no manager refresh
- `hid-lenovo-go` not bound (wrong controller mode / detached oddity) → script fails with “no handle dirs”

---

## 8. Upstream wish-list

Report to Valve / ShadowBlip:

1. Fix typo `imu_bypass_enable` → `imu_bypass_enabled` in `99-inputplumber-device-setup.rules`
2. Also set `imu_enabled=true` on both handles

When that ships, this overlay may become unnecessary — re-test and document.

---

## 9. Quick recovery decision tree

```text
Gyro dead after SteamOS update?
├─ Run ./fix-legion-go2-gyro.sh
│   ├─ Success → test in-game
│   └─ Failure → open debug dump from ~/Downloads
│         ├─ No hid-lenovo-go handles → controller mode / driver / USB
│         ├─ Attrs won't stick at true → kernel/sysfs / permissions
│         ├─ IP not active → systemctl status/journal inputplumber
│         └─ Attrs OK but no Gyroscope caps → IP version / profile / filtered events
└─ Attrs OK + caps OK but game dead → Steam Input binding / wrong target in that game
```

---

## 10. Related paths (reference)

| Path | Notes |
|------|--------|
| `/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules` | Stock (buggy names) |
| `/etc/udev/rules.d/99-legion-go2-imu-fix.rules` | Our fix |
| `/usr/share/inputplumber/devices/50-legion_go_2.yaml` | Composite device definition |
| `/usr/share/steamos-manager/devices/legion-go-series.toml` | Official targets |
| `/usr/lib/systemd/system/inputplumber.service` | Stock unit |

Repo automation: [`fix-legion-go2-gyro.sh`](fix-legion-go2-gyro.sh)
