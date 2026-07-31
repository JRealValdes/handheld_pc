#!/usr/bin/env bash
# Legion Go 2 gyro fix for SteamOS (InputPlumber + hid-lenovo-go).
#
# Scope (grows over time — see KNOWLEDGE.md §3 Documented failure cases):
#   Currently Case A only: stock udev writes imu_bypass_enable (missing "d")
#   and never sets imu_enabled, so controller gyros stay off.
#
# What it does NOT do (unless a future case documents otherwise):
#   No cleanups, no custom InputPlumber binaries, no profile/target changes.
#   SteamOS Manager already selects deck-uhid for Legion Go.
#
# Usage:
#   ./fix-legion-go2-gyro.sh
#   (will ask for admin password via pkexec if needed)

set -u

RULE_PATH="/etc/udev/rules.d/99-legion-go2-imu-fix.rules"
RULE_CONTENT='# Fix Legion Go / Go 2 IMU enable for hid-lenovo-go.
# Stock SteamOS rule uses imu_bypass_enable (missing trailing "d") and never sets imu_enabled.
ACTION=="add|change|bind", ATTRS{idVendor}=="17ef", ATTRS{idProduct}=="61e[bcde]", SUBSYSTEM=="hid", DRIVER=="hid-lenovo-go", ATTR{os_mode}="linux", ATTR{left_handle/imu_enabled}="true", ATTR{right_handle/imu_enabled}="true", ATTR{left_handle/imu_bypass_enabled}="true", ATTR{right_handle/imu_bypass_enabled}="true", ATTR{touchpad/vibration_enable}="false"
'

ERRORS=()
WARNINGS=()

log()  { printf '%s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS+=("$*"); }
fail() { printf '[FAIL] %s\n' "$*"; ERRORS+=("$*"); }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v pkexec >/dev/null 2>&1; then
      exec pkexec env DECK_HOME="${HOME:-/home/deck}" bash "$0" "$@"
    fi
    fail "Must run as root (pkexec/sudo not available)."
    dump_debug
    exit 1
  fi
}

read_trim() {
  local f="$1"
  if [[ -r "$f" ]]; then
    tr -d '\n' <"$f" 2>/dev/null || true
  else
    printf ''
  fi
}

handle_dirs() {
  shopt -s nullglob
  local dirs=(/sys/bus/hid/drivers/hid-lenovo-go/*/left_handle /sys/bus/hid/drivers/hid-lenovo-go/*/right_handle)
  shopt -u nullglob
  printf '%s\n' "${dirs[@]+"${dirs[@]}"}"
}

install_udev_rule() {
  log "==> Installing udev rule: $RULE_PATH"
  if ! printf '%s\n' "$RULE_CONTENT" >"$RULE_PATH"; then
    fail "Could not write $RULE_PATH"
    return 1
  fi
  ok "Wrote $RULE_PATH"

  if ! udevadm control --reload; then
    fail "udevadm control --reload failed"
    return 1
  fi
  ok "udevadm rules reloaded"

  # Best-effort re-apply; some kernels ignore filtered triggers.
  udevadm trigger -c change -s hid -a idVendor=17ef 2>/dev/null \
    || udevadm trigger -c change /sys/bus/hid/drivers/hid-lenovo-go 2>/dev/null \
    || warn "udevadm trigger did not complete cleanly (will set attrs directly)"
}

enable_imu_attrs() {
  log "==> Enabling controller IMU sysfs attributes"
  local dirs found=0
  mapfile -t dirs < <(handle_dirs)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    fail "No hid-lenovo-go left_handle/right_handle sysfs dirs found"
    return 1
  fi

  local dir attr path
  for dir in "${dirs[@]}"; do
    found=1
    for attr in imu_enabled imu_bypass_enabled; do
      path="$dir/$attr"
      if [[ ! -e "$path" ]]; then
        fail "Missing attribute: $path"
        continue
      fi
      if ! printf 'true\n' >"$path" 2>/dev/null; then
        fail "Could not write true to $path"
        continue
      fi
      local val
      val="$(read_trim "$path")"
      if [[ "$val" != "true" ]]; then
        fail "After write, $path reads '$val' (expected true)"
      else
        ok "$(basename "$(dirname "$dir")")/$(basename "$dir")/$attr=$val"
      fi
    done
  done

  [[ $found -eq 1 ]]
}

restart_inputplumber() {
  log "==> Restarting InputPlumber"
  if ! systemctl restart inputplumber.service; then
    fail "systemctl restart inputplumber.service failed"
    return 1
  fi
  # Give udev/source discovery a moment
  sleep 2
  if ! systemctl is-active --quiet inputplumber.service; then
    fail "inputplumber.service is not active after restart"
    return 1
  fi
  ok "inputplumber.service is active"
}

verify_fix() {
  log "==> Verifying fix"
  local ok_all=0
  local dirs
  mapfile -t dirs < <(handle_dirs)

  if [[ ${#dirs[@]} -eq 0 ]]; then
    fail "Verification: no handle sysfs dirs"
    return 1
  fi

  local dir attr path val
  for dir in "${dirs[@]}"; do
    for attr in imu_enabled imu_bypass_enabled; do
      path="$dir/$attr"
      val="$(read_trim "$path")"
      if [[ "$val" != "true" ]]; then
        fail "Verification failed: $path='$val'"
        ok_all=1
      fi
    done
  done

  if ! systemctl is-active --quiet inputplumber.service; then
    fail "Verification: inputplumber inactive"
    ok_all=1
  fi

  # Soft checks — useful signal, not hard requirements
  if command -v inputplumber >/dev/null 2>&1; then
    local caps targets
    caps="$(inputplumber device 0 capabilities 2>/dev/null || true)"
    targets="$(inputplumber device 0 targets list 2>/dev/null || true)"
    if printf '%s' "$caps" | grep -qi 'Gyroscope'; then
      ok "InputPlumber reports Gyroscope capabilities"
    else
      warn "InputPlumber device 0 has no Gyroscope capability string (may still work after Game Mode refresh)"
    fi
    if printf '%s' "$targets" | grep -Eqi 'deck|dualsense|ds5|horipad'; then
      ok "InputPlumber has a gyro-capable target (deck/dualsense/…)"
    else
      warn "No deck/dualsense-like target listed yet; steamos-manager normally sets deck-uhid shortly after boot"
    fi
  else
    warn "inputplumber CLI not found in PATH"
  fi

  return "$ok_all"
}

dump_debug() {
  local ts out
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  out="${DECK_HOME:-${HOME:-/home/deck}}/Downloads/legion-go2-gyro-debug-${ts}.txt"

  {
    echo "===== Legion Go 2 gyro fix DEBUG DUMP ====="
    echo "timestamp_utc: $ts"
    echo "script: $0"
    echo "hostname: $(hostname 2>/dev/null || true)"
    echo
    echo "----- reported errors -----"
    if [[ ${#ERRORS[@]} -eq 0 ]]; then
      echo "(none recorded)"
    else
      printf ' - %s\n' "${ERRORS[@]}"
    fi
    echo
    echo "----- warnings -----"
    if [[ ${#WARNINGS[@]} -eq 0 ]]; then
      echo "(none recorded)"
    else
      printf ' - %s\n' "${WARNINGS[@]}"
    fi
    echo
    echo "----- system -----"
    uname -a 2>&1 || true
    echo
    cat /etc/os-release 2>&1 || true
    echo
    echo "product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo '?')"
    echo "sys_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo '?')"
    echo
    echo "----- packages / binaries -----"
    pacman -Q inputplumber 2>&1 || true
    command -v inputplumber 2>&1 || true
    inputplumber --version 2>&1 || true
    echo "exe=$(readlink -f /proc/$(systemctl show -p MainPID --value inputplumber.service 2>/dev/null || echo 0)/exe 2>/dev/null || echo '?')"
    echo
    echo "----- systemd -----"
    systemctl status inputplumber.service --no-pager -l 2>&1 | head -80 || true
    echo
    systemctl cat inputplumber.service 2>&1 | head -60 || true
    echo
    ls -la /etc/systemd/system/inputplumber* /etc/systemd/system/inputplumber.service.d/ 2>&1 || true
    echo
    echo "----- steamos-manager legion targets (reference) -----"
    sed -n '1,80p' /usr/share/steamos-manager/devices/legion-go-series.toml 2>&1 || true
    echo
    echo "----- udev -----"
    ls -la /etc/udev/rules.d/ 2>&1 || true
    echo "--- our rule ($RULE_PATH) ---"
    cat "$RULE_PATH" 2>&1 || true
    echo "--- stock rule snippet ---"
    grep -n '61e\|imu_bypass\|imu_enabled\|hid-lenovo-go' \
      /usr/lib/udev/rules.d/99-inputplumber-device-setup.rules 2>&1 || true
    echo
    echo "----- kernel modules -----"
    lsmod 2>/dev/null | grep -E 'hid_lenovo_go|amd_sfh|hid_sensor|industrialio|inputplumber' || true
    echo
    modinfo hid_lenovo_go 2>&1 | head -30 || true
    echo
    echo "----- HID devices (Lenovo / SFH) -----"
    ls -la /sys/bus/hid/devices/ 2>&1 || true
    echo
    for d in /sys/bus/hid/devices/*; do
      [[ -e "$d/uevent" ]] || continue
      if grep -Eqi '17EF|1022:0001|61E[BCDE]|amdsfh|Legion' "$d/uevent" 2>/dev/null; then
        echo "== $d =="
        cat "$d/uevent" 2>&1 || true
        echo "driver=$(basename "$(readlink -f "$d/driver" 2>/dev/null || echo none)")"
      fi
    done
    echo
    echo "----- hid-lenovo-go driver attrs -----"
    ls -la /sys/bus/hid/drivers/hid-lenovo-go/ 2>&1 || true
    for d in /sys/bus/hid/drivers/hid-lenovo-go/*/; do
      [[ -d "$d" ]] || continue
      base="$(basename "$d")"
      [[ "$base" == "module" || "$base" == "uevent" ]] && continue
      echo "== $d =="
      ls -la "$d" 2>&1 | head -40 || true
      for side in left_handle right_handle; do
        if [[ -d "$d$side" ]]; then
          echo "-- $side --"
          for f in "$d$side"/*; do
            [[ -f "$f" ]] || continue
            # skip write-only calibrate nodes noise
            if [[ -r "$f" ]]; then
              printf '  %s=%s\n' "$(basename "$f")" "$(read_trim "$f")"
            else
              printf '  %s=(not readable)\n' "$(basename "$f")"
            fi
          done
        fi
      done
    done
    echo
    echo "----- IIO devices -----"
    ls -la /sys/bus/iio/devices/ 2>&1 || true
    for d in /sys/bus/iio/devices/iio:device*; do
      [[ -e "$d/name" ]] || continue
      echo "== $d name=$(cat "$d/name" 2>/dev/null) =="
      ls "$d" 2>&1 | head -40 || true
      for a in in_anglvel_x_raw in_anglvel_y_raw in_anglvel_z_raw in_anglvel_scale in_anglvel_sampling_frequency; do
        [[ -e "$d/$a" ]] && echo "  $a=$(read_trim "$d/$a")"
      done
    done
    echo
    echo "----- hidraw / input -----"
    ls -la /dev/hidraw* 2>&1 || true
    for e in /sys/class/input/event*/device/name; do
      [[ -e "$e" ]] || continue
      printf '  %s <- %s\n' "$(cat "$e" 2>/dev/null)" "$e"
    done 2>/dev/null | grep -Ei 'legion|gyro|imu|accel|motion|sensor|steam|inputplumber' || true
    echo
    echo "----- lsusb (Lenovo/Valve) -----"
    lsusb 2>&1 | grep -Ei '17ef|28de|Lenovo|Valve' || lsusb 2>&1 || true
    echo
    echo "----- InputPlumber CLI -----"
    inputplumber device 0 info 2>&1 || true
    echo
    inputplumber device 0 targets list 2>&1 || true
    echo
    inputplumber device 0 capabilities 2>&1 || true
    echo
    echo "----- journal inputplumber (last 120) -----"
    journalctl -u inputplumber.service -n 120 --no-pager 2>&1 || true
    echo
    echo "----- dmesg hid/sfh/iio/gyro (last matches) -----"
    dmesg 2>/dev/null | grep -Ei 'hid-lenovo|amd_sfh|sfh|iio|gyro|imu|mp2' | tail -80 || true
    echo
    echo "----- /etc inputplumber overlays (should usually be empty) -----"
    find /etc/inputplumber -type f 2>&1 || true
    echo
    echo "===== END DEBUG DUMP ====="
  } >"$out" 2>&1

  log ""
  log "Debug dump written to:"
  log "  $out"
  log "Attach that file when asking for help."
}

main() {
  need_root "$@"

  log "Legion Go 2 gyro fix"
  log "Scope: Case A — stock udev IMU attrs (see KNOWLEDGE.md); no cleanups, no custom binaries"
  log ""

  install_udev_rule || true
  enable_imu_attrs || true
  restart_inputplumber || true
  verify_fix || true

  log ""
  if [[ ${#ERRORS[@]} -eq 0 ]]; then
    ok "Fix applied and verified."
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
      log "Completed with warnings:"
      printf ' - %s\n' "${WARNINGS[@]}"
    fi
    log "Non-stock file: $RULE_PATH"
    exit 0
  fi

  fail "Fix did not fully succeed (${#ERRORS[@]} error(s))."
  dump_debug
  exit 1
}

main "$@"
