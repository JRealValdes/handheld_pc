#!/usr/bin/env bash
# Probe DualSense while the game says it is "dead".
# Run this IN ANOTHER TERMINAL after the in-game drop, with the pad still powered.
# Usage: ./probe-dualsense-alive.sh
# Optional: SAMPLE_SECS=8 ./probe-dualsense-alive.sh
set -euo pipefail

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
  REAL_HOME="${REAL_HOME:-/home/${SUDO_USER}}"
else
  REAL_HOME="${HOME}"
fi
OUT="${REAL_HOME}/Downloads/dualsense-alive-probe-${STAMP}.txt"
mkdir -p "${REAL_HOME}/Downloads"
SAMPLE_SECS="${SAMPLE_SECS:-6}"

section() { printf '\n======== %s ========\n' "$*"; }

find_mac() {
  if [[ -n "${DUALSENSE_MAC:-}" ]]; then
    printf '%s\n' "${DUALSENSE_MAC}"
    return
  fi
  bluetoothctl devices Connected 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /dualsense|wireless controller|sony/ {print $2; exit}'
}

find_event_nodes() {
  local name_file event_dir
  for name_file in /sys/class/input/event*/device/name; do
    [[ -e "$name_file" ]] || continue
    if grep -qx 'DualSense Wireless Controller' "$name_file" 2>/dev/null; then
      event_dir="$(dirname "$(dirname "$name_file")")"
      basename "$event_dir"
    fi
  done
}

find_hidraw() {
  local node
  for node in /dev/hidraw*; do
    [[ -e "$node" ]] || continue
    if udevadm info -q property -n "$node" 2>/dev/null | grep -qiE 'DualSense|054C:0CE6|054C_0CE6'; then
      printf '%s\n' "$node"
    fi
  done
}

count_uhid_playstation() {
  ls -d /sys/devices/virtual/misc/uhid/0005:054C:0CE6.* 2>/dev/null | wc -l
}

{
  section "dualsense alive probe @ $(date -u --iso-8601=seconds)"
  echo "host: $(hostname)"
  echo "sample_seconds: ${SAMPLE_SECS}"

  section "bluetoothctl devices Connected"
  bluetoothctl devices Connected 2>/dev/null || true

  MAC="$(find_mac || true)"
  echo "mac: ${MAC:-none}"
  if [[ -n "${MAC}" ]]; then
    section "bluetoothctl info ${MAC}"
    bluetoothctl info "$MAC" 2>/dev/null || true
  fi

  section "BlueZ input.conf (UserspaceHID)"
  if [[ -f /etc/bluetooth/input.conf ]]; then
    grep -E '^\s*UserspaceHID|^#UserspaceHID|^\[General\]' /etc/bluetooth/input.conf 2>/dev/null || cat /etc/bluetooth/input.conf
  else
    echo "(no /etc/bluetooth/input.conf — BlueZ default UserspaceHID=true / UHID)"
  fi
  echo "bluez packages:"
  (dpkg -l 'bluez*' 2>/dev/null || true) | awk '/^ii/ {print $2, $3}'

  section "uhid playstation nodes"
  echo "uhid_054C_0CE6_count: $(count_uhid_playstation)"
  ls -d /sys/devices/virtual/misc/uhid/0005:054C:* 2>/dev/null || echo "(none)"

  section "input device names (sony/dualsense)"
  matched=0
  for name_file in /sys/class/input/event*/device/name; do
    [[ -e "$name_file" ]] || continue
    n="$(cat "$name_file" 2>/dev/null || true)"
    if printf '%s' "$n" | grep -qiE 'dualsense|sony|playstation'; then
      printf '%s -> %s\n' "$(basename "$(dirname "$(dirname "$name_file")")")" "$n"
      matched=1
    fi
  done
  if [[ "$matched" -eq 0 ]]; then
    echo "(no matching input names)"
  fi

  EVENTS="$(find_event_nodes | tr '\n' ' ')"
  echo "main_event_nodes: ${EVENTS:-none}"

  HIDRAWS="$(find_hidraw | tr '\n' ' ')"
  echo "hidraw_nodes: ${HIDRAWS:-none}"

  section "all /dev/hidraw* (names)"
  for node in /dev/hidraw*; do
    [[ -e "$node" ]] || continue
    props="$(udevadm info -q property -n "$node" 2>/dev/null | grep -E 'ID_SERIAL|ID_MODEL|HID_ID|UNIQ' | tr '\n' ' ')"
    echo "${node}: ${props}"
  done

  section "lsof hidraw (best effort)"
  if [[ -n "${HIDRAWS}" ]]; then
    # shellcheck disable=SC2086
    lsof ${HIDRAWS} 2>/dev/null || echo "(no openers visible without root, or none open)"
  else
    echo "(no DualSense hidraw found)"
  fi

  section "recent kernel/bluetooth lines (playstation|uhid|hidraw|DualSense)"
  journalctl -k -n 120 --no-pager 2>/dev/null | grep -iE 'playstation|uhid|hidraw|DualSense|054C:0CE6' || echo "(none)"
  journalctl -u bluetooth -n 80 --no-pager 2>/dev/null | grep -iE 'hid|input|disconnect|DualSense|24:A6:FA' || echo "(no bluetooth.service hits)"

  section "processes: steam / proton / marvel"
  ps aux 2>/dev/null | grep -iE 'steam|proton|marvel|rivals|wine' | grep -v grep || true
} | tee "${OUT}"

EVENTS_NOW="$(find_event_nodes | tr '\n' ' ')"
if [[ -z "${EVENTS_NOW// }" ]]; then
  {
    section "VERDICT"
    if bluetoothctl devices Connected 2>/dev/null | grep -qiE 'dualsense|wireless controller|sony'; then
      echo "BT ACL: Connected YES"
      echo "Kernel HID: NO DualSense event/hidraw/uhid nodes"
      echo "→ HID/UHID session torn down while BlueZ keeps the link (not full radio drop,"
      echo "  and not 'game ignores a live pad'). This is the broken state."
      echo "→ Next: ./watch-hid-death.sh then launch the game; or try UserspaceHID=false (see KNOWLEDGE)."
    else
      echo "BT not connected + no HID nodes → full disconnect this time."
    fi
  } | tee -a "${OUT}"
  if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
    chown "${SUDO_USER}:${SUDO_USER}" "${OUT}" 2>/dev/null || true
  fi
  echo
  echo "Wrote: ${OUT}"
  echo "(No event sample — there is nothing to read. Stick movement cannot help in this state.)"
  exit 0
fi

echo
echo "DualSense event node(s) present: ${EVENTS_NOW}"
echo "When ready, MOVE STICKS / PRESS BUTTONS, then press ENTER to sample ${SAMPLE_SECS}s..."
read -r -p "Press ENTER to start sample... " _

{
  section "event sample (${SAMPLE_SECS}s)"
  local_ev_count=0
  for ev in $(find_event_nodes); do
    node="/dev/input/${ev}"
    [[ -e "$node" ]] || continue
    echo "--- sampling ${node} ---"
    if command -v evtest >/dev/null 2>&1; then
      set +e
      lines="$(timeout "${SAMPLE_SECS}" evtest "$node" 2>/dev/null | tee /dev/stderr | grep -c 'Event:' || true)"
      set -e
      echo "evtest_event_lines: ${lines}"
      if [[ "${lines}" -gt 0 ]]; then
        local_ev_count=$((local_ev_count + lines))
      fi
    else
      set +e
      bytes="$(timeout "${SAMPLE_SECS}" dd if="$node" bs=24 status=none 2>/dev/null | wc -c)"
      set -e
      echo "raw_bytes_read: ${bytes}"
      if [[ "${bytes}" -gt 0 ]]; then
        local_ev_count=$((local_ev_count + bytes))
      fi
    fi
  done

  section "VERDICT"
  if [[ "${local_ev_count}" -gt 0 ]]; then
    echo "BT: connected + kernel events FLOWING while game says dead."
    echo "→ Game/Proton/Steam is ignoring a live pad."
  else
    echo "BT: connected + event nodes exist but NO events in sample."
    echo "→ Confirm you moved sticks after ENTER; else hid stalled / exclusive grab."
  fi
} | tee -a "${OUT}"

if [[ -n "${SUDO_USER:-}" && "${EUID}" -eq 0 ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${OUT}" 2>/dev/null || true
fi

echo
echo "Wrote: ${OUT}"
echo "Paste the VERDICT section (or the whole file)."
