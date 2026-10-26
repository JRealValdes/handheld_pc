#!/usr/bin/env bash
# Capture DualSense Bluetooth disconnect while launching a Steam game.
# Usage: ./debug-dualsense-bt-disconnect.sh
# Optional: DUALSENSE_MAC=AA:BB:... ./debug-dualsense-bt-disconnect.sh
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# When run via sudo, write under the real user's Downloads (not /root).
if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  REAL_HOME="${REAL_HOME:-/home/${SUDO_USER}}"
else
  REAL_HOME="${HOME}"
fi
OUT_DIR="${REAL_HOME}/Downloads/dualsense-bt-disconnect-${STAMP}.d"
OUT_FILE="${REAL_HOME}/Downloads/dualsense-bt-disconnect-${STAMP}.txt"
mkdir -p "${OUT_DIR}" "${REAL_HOME}/Downloads"
if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${REAL_HOME}/Downloads" 2>/dev/null || true
fi

PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

log() { printf '%s\n' "$*"; }
section() { printf '\n======== %s ========\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_bg() {
  local name="$1"
  shift
  "$@" >"${OUT_DIR}/${name}.log" 2>&1 &
  PIDS+=("$!")
  log "  collector: ${name} (pid $!)"
}

# --- helpers ---------------------------------------------------------------

find_dualsense_macs() {
  if [[ -n "${DUALSENSE_MAC:-}" ]]; then
    printf '%s\n' "${DUALSENSE_MAC}"
    return
  fi
  if ! need_cmd bluetoothctl; then
    return
  fi
  local line mac name found=0
  # Prefer currently connected DualSense-like devices
  while IFS= read -r line; do
    mac="$(printf '%s' "$line" | awk '{print $2}')"
    name="$(printf '%s' "$line" | cut -d' ' -f3-)"
    if printf '%s' "$name" | grep -qiE 'dualsense|wireless controller|sony'; then
      printf '%s\n' "$mac"
      found=1
    fi
  done < <(bluetoothctl devices Connected 2>/dev/null || true)

  # Fall back to paired list if nothing connected matched
  if [[ "$found" -eq 0 ]]; then
    while IFS= read -r line; do
      mac="$(printf '%s' "$line" | awk '{print $2}')"
      name="$(printf '%s' "$line" | cut -d' ' -f3-)"
      if printf '%s' "$name" | grep -qiE 'dualsense|wireless controller|sony'; then
        printf '%s\n' "$mac"
      fi
    done < <(bluetoothctl devices 2>/dev/null || true)
  fi
}

snapshot_state() {
  local tag="$1"
  local f="${OUT_DIR}/snapshot-${tag}.txt"
  {
    section "snapshot ${tag} @ $(date -u --iso-8601=seconds)"
    section "uname"
    uname -a || true
    section "bluetoothctl devices Connected"
    bluetoothctl devices Connected 2>/dev/null || true
    section "bluetoothctl devices"
    bluetoothctl devices 2>/dev/null || true

    local mac
    while IFS= read -r mac; do
      [[ -z "$mac" ]] && continue
      section "bluetoothctl info ${mac}"
      bluetoothctl info "$mac" 2>/dev/null || true
    done < <(find_dualsense_macs | sort -u)

    section "kernel modules (hid / bluetooth)"
    lsmod | grep -iE 'hid_playstation|hid_sony|bluetooth|btusb|hci' || true

    section "/dev/hidraw* + input js/event (names)"
    ls -l /dev/hidraw* /dev/input/js* 2>/dev/null || true
    if need_cmd udevadm; then
      local node
      for node in /dev/hidraw*; do
        [[ -e "$node" ]] || continue
        echo "--- udevadm info ${node} ---"
        udevadm info -q property -n "$node" 2>/dev/null | grep -iE 'ID_SERIAL|ID_MODEL|ID_VENDOR|HID_ID|UNIQ|NAME' || true
      done
    fi
    if need_cmd cat; then
      for node in /sys/class/input/event*/device/name; do
        [[ -e "$node" ]] || continue
        printf '%s: %s\n' "$node" "$(cat "$node" 2>/dev/null || true)"
      done | grep -iE 'dualsense|sony|wireless|gamepad|playstation' || true
    fi

    section "processes that look related"
    ps aux 2>/dev/null | grep -iE 'steam|proton|marvel|dualsense|bluetoothd|hid' | grep -v grep || true

    if need_cmd lsof; then
      section "lsof hidraw (may need root — best effort)"
      lsof /dev/hidraw* 2>/dev/null || true
    fi

    section "rfkill"
    rfkill list 2>/dev/null || true

    section "recent kernel lines (hid|bluetooth|sony|playstation)"
    journalctl -k -n 80 --no-pager 2>/dev/null | grep -iE 'hid|bluetooth|sony|playstation|dualsense' || true
  } >"$f"
  log "  wrote ${f}"
}

summarize() {
  local summary="${OUT_DIR}/SUMMARY.txt"
  {
    section "SUMMARY"
    echo "stamp: ${STAMP}"
    echo "host: $(hostname 2>/dev/null || echo '?')"
    echo "generated: $(date -u --iso-8601=seconds)"
    echo

    echo "--- Connected after capture ---"
    bluetoothctl devices Connected 2>/dev/null || true
    echo

    echo "--- Likely disconnect / HCI lines (live journals only; not full boot dmesg) ---"
    grep -hniE 'disconnect|Disconnected|reason [0-9]|timeout|hid-playstation|hid_playstation|DualSense|playstation ' \
      "${OUT_DIR}/journal-bluetooth.log" \
      "${OUT_DIR}/journal-kernel.log" \
      2>/dev/null | tail -n 80 || echo "(no matches)"
    echo

    if [[ -f "${OUT_DIR}/btmon.log" ]]; then
      echo "--- btmon reason-ish lines ---"
      grep -niE 'Disconnect|Reason:|Remote User|Local Host|Connection Timeout|supervis' \
        "${OUT_DIR}/btmon.log" 2>/dev/null | tail -n 40 || echo "(no matches)"
      echo
    else
      echo "--- btmon ---"
      echo "(not captured — install bluez and re-run with sudo if needed)"
      echo
    fi

    echo "--- udev hid/input/bluetooth during capture ---"
    if [[ -f "${OUT_DIR}/udev-monitor.log" ]]; then
      grep -iE 'hid|input|bluetooth|remove|add' "${OUT_DIR}/udev-monitor.log" 2>/dev/null | tail -n 40 || echo "(no matches)"
    else
      echo "(no udev-monitor.log)"
    fi
    echo

    echo "--- Layer hint ---"
    local still_connected=0
    if bluetoothctl devices Connected 2>/dev/null | grep -qiE 'dualsense|wireless controller|sony'; then
      still_connected=1
    fi
    if grep -qiE 'Disconnected|Connection Timeout' "${OUT_DIR}/journal-bluetooth.log" 2>/dev/null \
      || grep -qiE 'Bluetooth: hci.*disconnected|disconnect.*reason' "${OUT_DIR}/journal-kernel.log" 2>/dev/null; then
      echo "BT/HCI disconnect seen → lean H1/H4/H5 (link or profile)."
    elif [[ "$still_connected" -eq 1 ]]; then
      echo "Pad still Connected in BlueZ and no HCI drop → lean H3/H6 (Steam Input / hidraw / game), not radio."
    else
      echo "Pad not Connected after capture but journals quiet — check bluetoothctl-monitor.log and snapshots."
    fi
    echo
    echo "Next: compare snapshot-before.txt vs snapshot-after.txt"
    echo "      and note exact game launch time vs first disconnect line."
  } | tee "$summary"
}

# --- main ------------------------------------------------------------------

log "DualSense BT disconnect debug capture"
log "Output dir:  ${OUT_DIR}"
log "Report file: ${OUT_FILE}"
log ""

if ! need_cmd bluetoothctl; then
  log "ERROR: bluetoothctl not found (install bluez)."
  exit 1
fi

MACS="$(find_dualsense_macs | sort -u | tr '\n' ' ')"
if [[ -z "${MACS// }" ]]; then
  log "NOTE: no DualSense-like device found yet."
  log "      Connect it over Bluetooth, then continue."
else
  log "DualSense-like MAC(s): ${MACS}"
fi

log ""
log "Taking BEFORE snapshot..."
snapshot_state before

log ""
log "Starting live collectors (reproduce the bug now)..."
run_bg journal-bluetooth journalctl -f -u bluetooth.service --no-pager
run_bg journal-kernel journalctl -k -f --no-pager
if need_cmd dmesg; then
  # follow if supported
  if dmesg --help 2>&1 | grep -q -- '--follow'; then
    run_bg dmesg-follow dmesg --follow --ctime
  else
    run_bg dmesg-follow bash -c 'while true; do dmesg -T | tail -n 5; sleep 1; done'
  fi
fi
if need_cmd udevadm; then
  run_bg udev-monitor udevadm monitor --udev --kernel --subsystem-match=hid --subsystem-match=bluetooth --subsystem-match=input
fi
if need_cmd bluetoothctl; then
  run_bg bluetoothctl-monitor bluetoothctl --monitor
fi

BTMON_NOTE=""
if need_cmd btmon; then
  if [[ "${EUID}" -eq 0 ]]; then
    run_bg btmon btmon -t
  else
    # try passwordless / may fail
    if btmon -t true >/dev/null 2>&1; then
      run_bg btmon btmon -t
    else
      BTMON_NOTE="btmon needs root — re-run with: sudo $0"
      log "  collector: btmon SKIPPED (${BTMON_NOTE})"
    fi
  fi
else
  BTMON_NOTE="btmon not installed (apt: bluez)"
  log "  collector: btmon SKIPPED (${BTMON_NOTE})"
fi

# Steam stderr if we can find a recent log dir (best effort, non-fatal)
STEAM_LOG_ROOT="${HOME}/.steam/steam/logs"
if [[ -d "${STEAM_LOG_ROOT}" ]]; then
  run_bg steam-logs-tail bash -c "tail -n 0 -F \"${STEAM_LOG_ROOT}\"/*.txt 2>/dev/null"
  log "  also watching ${STEAM_LOG_ROOT}/*.txt"
fi

log ""
log "============================================================"
log " Reproduce now:"
log "   1) DualSense connected over Bluetooth"
log "   2) Steam already sees the DualSense"
log "   3) Launch the game that drops it (e.g. Marvel Rivals)"
log "   4) Wait until disconnect (or ~60s)"
log "   5) Come back here and press ENTER"
log "============================================================"
if [[ -n "${BTMON_NOTE}" ]]; then
  log "Note: ${BTMON_NOTE}"
fi
log ""
read -r -p "Press ENTER when the disconnect happened (or you gave up)... " _

log ""
log "Stopping collectors..."
cleanup
trap - EXIT
sleep 0.5

log "Taking AFTER snapshot..."
snapshot_state after

summarize

{
  section "dualsense-bt-disconnect debug report"
  echo "stamp: ${STAMP}"
  echo "btmon_note: ${BTMON_NOTE:-none}"
  echo
  cat "${OUT_DIR}/SUMMARY.txt"
  echo
  section "snapshot-before"
  cat "${OUT_DIR}/snapshot-before.txt"
  echo
  section "snapshot-after"
  cat "${OUT_DIR}/snapshot-after.txt"
  echo
  for f in journal-bluetooth journal-kernel dmesg-follow udev-monitor bluetoothctl-monitor btmon steam-logs-tail; do
    if [[ -f "${OUT_DIR}/${f}.log" ]]; then
      section "${f}.log (tail 200)"
      tail -n 200 "${OUT_DIR}/${f}.log" || true
      echo
    fi
  done
} >"${OUT_FILE}"

if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${OUT_DIR}" "${OUT_FILE}" 2>/dev/null || true
fi

log ""
log "Done."
log "  Report: ${OUT_FILE}"
log "  Raw:    ${OUT_DIR}/"
log "Share the report (or at least SUMMARY + snapshot before/after)."
