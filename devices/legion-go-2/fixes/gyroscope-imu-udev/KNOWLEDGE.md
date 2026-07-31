# Legion Go 2 — Gyroscope knowledge base

Durable context for SteamOS + InputPlumber on the Legion Go 2. Use this as the baseline for diagnosis after updates or AI session resets.

Gyro can fail for more than one reason. This file holds **architecture** (always useful) plus **documented failure cases** learned from real incidents. New cases should be added here as they are found; the fix script grows the same way.

**Verified on:** SteamOS 3.8.16 · kernel `6.16.12-valve24.5-1-neptune-616` · `inputplumber` 0.77.4–0.78.0 · handle FW `260310a` · USB `17ef:61eb`

**Scope of truth:** Facts below were confirmed on that stack at the time of writing. SteamOS, InputPlumber, `hid-lenovo-go`, and Lenovo firmware change. Treat this as a working baseline — re-verify after updates, and revise this file when behavior or paths diverge. It is not a permanently frozen truth.

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

Any break in that chain can kill in-game gyro. Diagnose against the chain; do not assume a single historical bug.

On Go 2, Steam Input gyro depends on the **controller (handle) IMUs**. Prefer stock `/usr/bin/inputplumber` and `/etc` overlays over custom binaries.

---

## 2. Architecture cheat sheet

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

Healthy for handle motion: all four = `true`.

### Screen IIO gyro

- Exists via AMD SFH (`pcie_mp2_amd`) → `HID-SENSOR-200076` → IIO `gyro_3d`.
- InputPlumber does **not** drive Steam gyro from the IIO buffer; it polls `*_raw` via libiio when it uses IIO at all.
- When `hid_lenovo_go` is loaded, stock IP filters the screen/center IIO path and expects handle IMUs. If handles are off → zero gyro total.
- `iio:device0` is often **ALS**, not gyro — always check `name`. Gyro name: `gyro_3d`.

---

## 3. Documented failure cases

Add a subsection when a new root cause is confirmed. Keep each case self-contained: symptom, cause, fix, how to recognize it again.

### Case A — Stock udev never enables handle IMUs

**Status:** Known; automated by `fix-legion-go2-gyro.sh` (current script scope).

**Symptom:** Gyro dead in Steam Input / games while InputPlumber is running.

**Cause:** Stock `/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules` writes `imu_bypass_enable` (missing final `d`) and never sets `imu_enabled`. Real attrs are `imu_enabled` and `imu_bypass_enabled`. Handle IMUs stay off.

**Persistent fix we own for this case:**

`/etc/udev/rules.d/99-legion-go2-imu-fix.rules`

**How to recognize again:**

```bash
# Attrs not true
for d in /sys/bus/hid/drivers/hid-lenovo-go/*/left_handle \
         /sys/bus/hid/drivers/hid-lenovo-go/*/right_handle; do
  echo "$d: enabled=$(cat "$d/imu_enabled") bypass=$(cat "$d/imu_bypass_enabled")"
done

# Stock still uses the wrong name
grep imu_bypass /usr/lib/udev/rules.d/99-inputplumber-device-setup.rules
```

**Upstream wish (Case A):** Valve / ShadowBlip fix the typo and also set `imu_enabled=true` on both handles. When that ships, the overlay may be unnecessary — re-test and update this case.

---

## 4. Fix script

```bash
cd "devices/legion-go-2/fixes/gyroscope-imu-udev"
./fix-legion-go2-gyro.sh
```

**Current scope:** Case A only (udev overlay + set the four IMU attrs + restart InputPlumber + verify).

**Intent:** Grow this script as new failure cases are documented in §3 — same entry point, broader coverage over time.

On failure → `~/Downloads/legion-go2-gyro-debug-<UTC>.txt`

**Does not (unless a future case documents otherwise):** install custom IP binaries, change profiles, force `deck` vs `deck-uhid`, clean home directories.

---

## 5. Verification checklist

Run on the Legion Go 2 (Desktop mode is fine). Useful for any suspected gyro break; Case A items are marked.

### A. IMU attrs (Case A)

```bash
for d in /sys/bus/hid/drivers/hid-lenovo-go/*/left_handle \
         /sys/bus/hid/drivers/hid-lenovo-go/*/right_handle; do
  echo "$d: enabled=$(cat "$d/imu_enabled") bypass=$(cat "$d/imu_bypass_enabled")"
done
```

Expect: `enabled=true bypass=true` for both.

### B. Case A overlay (if that case still applies)

```bash
cat /etc/udev/rules.d/99-legion-go2-imu-fix.rules
```

Must mention `imu_enabled` and `imu_bypass_enabled` (with **d**).

### C. Stock udev (Case A still present?)

```bash
grep imu_bypass /usr/lib/udev/rules.d/99-inputplumber-device-setup.rules
```

If stock still says `imu_bypass_enable` (no `d`), Case A remains relevant. If stock is corrected upstream, re-test without the overlay and update §3.

### D. InputPlumber process

```bash
systemctl is-active inputplumber
readlink -f /proc/$(systemctl show -p MainPID --value inputplumber)/exe
```

Expect: `active` and `/usr/bin/inputplumber` (not a custom path under `~/Applications`).

### E. Targets

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

## 6. Anti-patterns

| Mistake | Why it hurts |
|---------|----------------|
| Custom InputPlumber with `GYRO_GAIN=50` | Handle values are already i16-scale; ×50 saturates → jumpy gyro |
| systemd override to a home-built IP binary | Breaks on updates; hides stock fixes |
| Forcing `deck` via oneshot while fighting manager | steamos-manager already sets `deck-uhid` (has gyro) |
| Chasing IIO `buffer/enable` as the Steam blocker | IP does not use that buffer for the handle path |
| Assuming `iio:device0` is always gyro | Often ALS; read `name` |
| Enabling IIO screen gyro *and* handle gyros with huge gain | Double path + bad scale → chaos |
| Editing `/usr/share/inputplumber/...` only | SteamOS updates overwrite `/usr`; prefer `/etc` overlays or udev |
| Treating Case A as the only possible failure | Other breaks exist; diagnose the full chain in §1 |

---

## 7. Healthy vs broken snapshot

### Healthy (handle path)

- Four IMU attrs `true`
- Case A overlay present while stock udev is still wrong (or attrs otherwise reliably `true`)
- `/usr/bin/inputplumber` running
- Targets include `deck-uhid` (or `deck` / DualSense)
- Capabilities include `Gyroscope:*`
- No `ExecStart=` override under `/etc/systemd/system/inputplumber.service.d/`

### Broken (examples)

- Case A: attrs `false` / `unknown` after update that left only stock udev
- Custom binary / `GYRO_GAIN` override left behind
- Only `xbox-elite` target and no manager refresh
- `hid-lenovo-go` not bound (wrong controller mode / detached oddity) → script fails with “no handle dirs”
- Attrs and caps OK but game dead → Steam Input binding / per-game target

---

## 8. Quick recovery decision tree

```text
Gyro dead after SteamOS update?
├─ Run ./fix-legion-go2-gyro.sh   (currently Case A)
│   ├─ Success → test in-game
│   └─ Failure → open debug dump from ~/Downloads
│         ├─ No hid-lenovo-go handles → controller mode / driver / USB
│         ├─ Attrs won't stick at true → kernel/sysfs / permissions
│         ├─ IP not active → systemctl status/journal inputplumber
│         └─ Attrs OK but no Gyroscope caps → IP version / profile / filtered events
│             (may be a new case — document in §3)
└─ Attrs OK + caps OK but game dead → Steam Input binding / wrong target in that game
```

---

## 9. Related paths

| Path | Notes |
|------|--------|
| `/usr/lib/udev/rules.d/99-inputplumber-device-setup.rules` | Stock (Case A: buggy names on verified stack) |
| `/etc/udev/rules.d/99-legion-go2-imu-fix.rules` | Case A overlay |
| `/usr/share/inputplumber/devices/50-legion_go_2.yaml` | Composite device definition |
| `/usr/share/steamos-manager/devices/legion-go-series.toml` | Official targets |
| `/usr/lib/systemd/system/inputplumber.service` | Stock unit |

Repo automation: [`fix-legion-go2-gyro.sh`](fix-legion-go2-gyro.sh)
