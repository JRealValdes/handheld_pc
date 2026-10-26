#!/usr/bin/env bash
# Watch DualSense HID/uhid disappear while launching the game.
# Usage:
#   1) DualSense working (Steam sees it, sticks work outside the game)
#   2) ./watch-hid-death.sh
#   3) When it says so, launch Marvel Rivals
#   4) Wait until pad dies; press ENTER
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  REAL_HOME="${REAL_HOME:-/home/${SUDO_USER}}"
else
  REAL_HOME="${HOME}"
fi
OUT_DIR="${REAL_HOME}/Downloads/dualsense-hid-death-${STAMP}.d"
OUT="${REAL_HOME}/Downloads/dualsense-hid-death-${STAMP}.txt"
mkdir -p "${OUT_DIR}" "${REAL_HOME}/Downloads"

PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

section() { printf '\n======== %s ========\n' "$*"; }
log() { printf '%s\n' "$*"; }

snapshot() {
  local tag="$1"
  {
    section "snapshot ${tag} @ $(date -u --iso-8601=seconds)"
    echo "Connected:"
    bluetoothctl devices Connected 2>/dev/null || true
    echo
    echo "uhid DualSense:"
    ls -d /sys/devices/virtual/misc/uhid/0005:054C:0CE6.* 2>/dev/null || echo "(none)"
    echo
    echo "input names:"
    for name_file in /sys/class/input/event*/device/name; do
      [[ -e "$name_file" ]] || continue
      n="$(cat "$name_file" 2>/dev/null || true)"
      if printf '%s' "$n" | grep -qiE 'dualsense|sony|playstation'; then
        printf '%s -> %s\n' "$(basename "$(dirname "$(dirname "$name_file")")")" "$n"
      fi
    done
    echo
    echo "hidraw:"
    ls -l /dev/hidraw* 2>/dev/null || true
  } >"${OUT_DIR}/snapshot-${tag}.txt"
  log "  wrote snapshot-${tag}.txt"
}

log "DualSense HID-death watcher"
log "Output: ${OUT}"
log ""

snapshot before

log "Starting collectors..."
udevadm monitor --udev --kernel --subsystem-match=hid --subsystem-match=input --subsystem-match=bluetooth \
  >"${OUT_DIR}/udev.log" 2>&1 &
PIDS+=("$!")
journalctl -f -u bluetooth.service --no-pager >"${OUT_DIR}/journal-bluetooth.log" 2>&1 &
PIDS+=("$!")
journalctl -k -f --no-pager >"${OUT_DIR}/journal-kernel.log" 2>&1 &
PIDS+=("$!")
if command -v btmon >/dev/null 2>&1 && [[ "${EUID}" -eq 0 ]]; then
  btmon -t >"${OUT_DIR}/btmon.log" 2>&1 &
  PIDS+=("$!")
  log "  btmon on"
else
  log "  btmon skipped (need sudo for HCI)"
fi

log ""
log "============================================================"
log " Confirm DualSense works NOW (Steam / desktop)."
log " Then launch the game that kills HID."
log " When the pad is dead, press ENTER here."
log "============================================================"
read -r -p "Press ENTER after HID death... " _

cleanup
trap - EXIT
sleep 0.3
snapshot after

{
  section "hid-death report ${STAMP}"
  section "SUMMARY"
  echo "before uhid:"
  grep -E 'uhid|none|event|DualSense|Connected|Device' "${OUT_DIR}/snapshot-before.txt" || true
  echo
  echo "after uhid:"
  grep -E 'uhid|none|event|DualSense|Connected|Device' "${OUT_DIR}/snapshot-after.txt" || true
  echo
  echo "--- udev remove/add (hid|input|uhid) ---"
  grep -iE 'remove|add|uhid|hid|input|054C|DualSense' "${OUT_DIR}/udev.log" 2>/dev/null | tail -n 80 || true
  echo
  echo "--- kernel playstation/uhid ---"
  grep -iE 'playstation|uhid|DualSense|hidraw|054C' "${OUT_DIR}/journal-kernel.log" 2>/dev/null | tail -n 60 || true
  echo
  echo "--- bluetoothd ---"
  grep -iE 'hid|input|disconnect|uhid|DualSense|24:A6' "${OUT_DIR}/journal-bluetooth.log" 2>/dev/null | tail -n 60 || true
  if [[ -f "${OUT_DIR}/btmon.log" ]]; then
    echo
    echo "--- btmon HID/disconnect-ish ---"
    grep -niE 'HID|Disconnect|Channel|PSM|reason' "${OUT_DIR}/btmon.log" 2>/dev/null | tail -n 80 || true
  fi
  echo
  section "snapshot-before"
  cat "${OUT_DIR}/snapshot-before.txt"
  echo
  section "snapshot-after"
  cat "${OUT_DIR}/snapshot-after.txt"
} | tee "${OUT}"

if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  chown -R "${SUDO_USER}:${SUDO_USER}" "${OUT_DIR}" "${OUT}" 2>/dev/null || true
fi

log ""
log "Done: ${OUT}"
log "Paste SUMMARY (udev remove lines + before/after uhid)."
