#!/usr/bin/env bash
# Legion Go 2: trace + light repair for gamepad vs keyboard after suspend/resume.
#
# The game reads Steam's XInput pad (built from InputPlumber deck-uhid 28de:12fb).
# The Legion/home button comes from the InputPlumber keyboard target. Those can
# diverge after resume. On each resume the watcher dumps state and tries two
# stock-path repairs (sealed deck-uhid ACL → bounce; Proton winebus IN_ATTRIB
# touch on the 360 pad). See KNOWLEDGE.md H1/H2.
#
# Usage:
#   ./trace-legion-go2-resume-gamepad.sh snapshot     # one dump, now
#   ./trace-legion-go2-resume-gamepad.sh mark [note]  # dump while the bug is visible
#   ./trace-legion-go2-resume-gamepad.sh watch        # foreground: pre + post on each suspend
#   ./trace-legion-go2-resume-gamepad.sh install      # systemd service (pkexec), survives Game Mode
#   ./trace-legion-go2-resume-gamepad.sh uninstall
#   ./trace-legion-go2-resume-gamepad.sh find 21:40   # cycle whose resume time matches
#   ./trace-legion-go2-resume-gamepad.sh status
#   ./trace-legion-go2-resume-gamepad.sh nudge        # run repair once now (Desktop/agent)

set -u

DECK_HOME="${DECK_HOME:-${HOME:-/home/deck}}"
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  DECK_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  DECK_HOME="${DECK_HOME:-/home/${SUDO_USER}}"
fi
# pkexec does not set SUDO_USER; the unit pins DECK_HOME=/home/deck.
if [[ "${EUID:-$(id -u)}" -eq 0 && "$DECK_HOME" == /root ]]; then
  DECK_HOME="/home/deck"
fi

BASE_DIR="${DECK_HOME}/legion-go2-resume-gamepad"
CYCLE_ROOT="${BASE_DIR}/cycles"
STATE_DIR="${BASE_DIR}/state"
INDEX_FILE="${BASE_DIR}/index.txt"
LOCK_FILE="${BASE_DIR}/watch.lock"
UNIT_NAME="legion-go2-resume-gamepad-trace.service"
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
STEAM_LOG_DIR="${DECK_HOME}/.local/share/Steam/logs"
# Each suspend is its own directory. Switching Game Mode → Desktop is not a
# suspend and does not delete these. Keep enough that a later resume cannot
# erase the one the user will report by clock time.
KEEP_CYCLES=20

log()  { printf '%s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

script_path() {
  readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s\n' "$0"
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec env DECK_HOME="${DECK_HOME}" bash "$0" "$@"
  fi
  warn "Must run as root (pkexec/sudo not available)."
  exit 1
}

ensure_dirs() {
  mkdir -p "$CYCLE_ROOT" "$STATE_DIR"
}

stamp() { date +%Y%m%d-%H%M%S; }

prune_cycles() {
  local old
  # Newest first; delete past KEEP_CYCLES.
  mapfile -t old < <(ls -1dt "$CYCLE_ROOT"/cycle-* 2>/dev/null || true)
  if [[ ${#old[@]} -le $KEEP_CYCLES ]]; then
    return 0
  fi
  local i
  for ((i = KEEP_CYCLES; i < ${#old[@]}; i++)); do
    rm -rf "${old[$i]}"
  done
}

new_cycle() {
  local reason="${1:-cycle}"
  ensure_dirs
  local dir="${CYCLE_ROOT}/cycle-$(stamp)"
  mkdir -p "$dir"
  printf '%s\n' "$reason" >"${dir}/reason.txt"
  printf '%s\n' "$dir" >"${STATE_DIR}/active-cycle"
  ln -sfn "$dir" "${BASE_DIR}/LATEST"
  prune_cycles
  printf '%s\n' "$dir"
}

publish_tree() {
  local path="$1"
  if [[ "${EUID:-$(id -u)}" -eq 0 && -e "$path" ]]; then
    chown -R deck:deck "$path" 2>/dev/null || true
  fi
}

# Append-only. Desktop session start does not rewrite this file.
note_event() {
  local dir="$1" key="$2" now
  now="$(date -Is)"
  printf '%s %s\n' "$key" "$now" >>"${dir}/when.txt"
  printf '%s %s %s\n' "$now" "$key" "$dir" >>"$INDEX_FILE"
  publish_tree "${dir}/when.txt"
  publish_tree "$INDEX_FILE"
}

# Copy Steam controller logs into the cycle dir immediately. Game Mode → Desktop
# restarts Steam and can rotate controller.txt; the copies here stay.
copy_steam_tails() {
  local dir="$1" tag="$2" f base dest
  mkdir -p "$dir"
  for f in controller.txt controller_ui.txt controller.previous.txt controller_ui.previous.txt; do
    [[ -r "${STEAM_LOG_DIR}/${f}" ]] || continue
    base="${f%.txt}"
    dest="${dir}/steam-${tag}-${base}.txt"
    tail -n 250 "${STEAM_LOG_DIR}/${f}" >"$dest" 2>/dev/null || true
    publish_tree "$dest"
  done
}

# Fast-ish state dump. Safe to call as the user; holders need root.
write_snapshot() {
  local out="$1"
  local tag="${2:-manual}"
  {
    echo "===== Legion Go 2 resume-gamepad ($tag) ====="
    echo "time: $(date -Is)"
    echo "uid: $(id -u 2>/dev/null) user: $(id -un 2>/dev/null)"
    echo "uptime: $(tr -d '\n' </proc/uptime 2>/dev/null)"
    echo
    echo "----- versions -----"
    grep -E '^(VERSION_ID|BUILD_ID|VARIANT_ID)=' /etc/os-release 2>/dev/null || true
    uname -r
    command -v inputplumber >/dev/null 2>&1 && inputplumber --version 2>/dev/null || true
    echo

    echo "----- usb 17ef / 28de -----"
    lsusb 2>/dev/null | grep -Ei '17ef|28de|Lenovo|Valve' || echo "(lsusb match empty)"
    echo

    echo "----- hid-lenovo-go -----"
    local d
    shopt -s nullglob
    local found=0
    for d in /sys/bus/hid/drivers/hid-lenovo-go/0003:*; do
      found=1
      echo "$d"
    done
    shopt -u nullglob
    [[ "$found" -eq 1 ]] || echo "(driver bound to nothing)"
    echo

    echo "----- input devices (legion / xbox / inputplumber / valve) -----"
    awk '
      BEGIN { RS=""; FS="\n" }
      {
        blob=$0
        if (blob ~ /17ef|17EF|28de|28DE|Legion|X-Box|Xbox|InputPlumber|Steam Deck|steamos-manager/)
          print blob "\n"
      }
    ' /proc/bus/input/devices 2>/dev/null || true
    echo

    echo "----- hidraw map + mode -----"
    local h name
    shopt -s nullglob
    for h in /sys/class/hidraw/hidraw*; do
      name="$(basename "$h")"
      echo "== $name =="
      if [[ -r "$h/device/uevent" ]]; then
        grep -E '^(DRIVER|HID_ID|HID_NAME|HID_PHYS)=' "$h/device/uevent" 2>/dev/null || true
      fi
      if [[ -e "/dev/$name" ]]; then
        stat -c 'mode=%a %A' "/dev/$name" 2>/dev/null || true
        if command -v getfacl >/dev/null 2>&1; then
          getfacl -p "/dev/$name" 2>/dev/null | grep -E '^(user:|group:|mask:|other:)' || true
        fi
      fi
    done
    shopt -u nullglob
    echo

    echo "----- uhid 28de:12fb (virtual Legion Go 2 Controller) -----"
    shopt -s nullglob
    local u
    found=0
    for u in /sys/devices/virtual/misc/uhid/0003:28DE:12FB.*; do
      found=1
      echo "$u"
      grep -E '^(DRIVER|HID_ID|HID_NAME)=' "$u/uevent" 2>/dev/null || true
      ls -d "$u"/hidraw/hidraw* 2>/dev/null || true
    done
    shopt -u nullglob
    [[ "$found" -eq 1 ]] || echo "(no 28de:12fb uhid)"
    echo

    echo "----- inputplumber composite -----"
    if command -v inputplumber >/dev/null 2>&1; then
      echo "--- devices list ---"
      inputplumber devices list 2>&1 || true
      echo "--- devices order ---"
      inputplumber devices order 2>&1 || true
      echo "--- device 0 info ---"
      inputplumber device 0 info 2>&1 || true
      echo "--- device 0 targets ---"
      inputplumber device 0 targets list 2>&1 || true
    else
      echo "(inputplumber not in PATH)"
    fi
    echo

    echo "----- session / compositor -----"
    loginctl list-sessions --no-pager 2>/dev/null || true
    ps -eo pid,user,comm,args 2>/dev/null | awk '
      BEGIN { IGNORECASE=1 }
      /gamescope|kwin_wayland|inputplumber/ && !/awk/ { print }
    ' | head -20 || true
    echo
    echo "----- steam transient apps -----"
    ls /run/user/1000/systemd/transient 2>/dev/null | head -30 || echo "(none or unreadable)"
    echo

    if [[ "${EUID:-$(id -u)}" -eq 0 && "$tag" != "pre" ]]; then
      echo "----- open hidraw/js/event fds (root) -----"
      local pid comm target
      shopt -s nullglob
      for pid in /proc/[0-9]*; do
        comm="$(tr -d '\0' <"$pid/comm" 2>/dev/null || true)"
        for target in "$pid"/fd/*; do
          link="$(readlink "$target" 2>/dev/null || true)"
          [[ "$link" == /dev/hidraw* || "$link" == /dev/input/event* || "$link" == /dev/input/js* || "$link" == *"(deleted)"* ]] || continue
          if [[ "$link" == /dev/input/event* && "$link" != *deleted* ]]; then
            ev="${link##*/}"
            evname="$(cat "/sys/class/input/$ev/device/name" 2>/dev/null || true)"
            case "$evname" in
              *Legion*|*X-Box*|*Xbox*|*InputPlumber*|*Steam*|*28de*) ;;
              *) continue ;;
            esac
            printf 'pid=%s comm=%s fd=%s -> %s (%s)\n' "${pid#/proc/}" "$comm" "${target##*/}" "$link" "$evname"
          else
            printf 'pid=%s comm=%s fd=%s -> %s\n' "${pid#/proc/}" "$comm" "${target##*/}" "$link"
          fi
        done
      done
      shopt -u nullglob
      echo
    elif [[ "$tag" == "pre" ]]; then
      echo "----- open fds -----"
      echo "(skipped on pre, to stay out of the way of suspend)"
      echo
    else
      echo "----- open fds -----"
      echo "(skipped: not root. install the service, or run mark via pkexec, to see who holds hidraw)"
      echo
    fi

    echo "----- signals -----"
    if command -v inputplumber >/dev/null 2>&1; then
      local order_out info_out
      order_out="$(inputplumber devices order 2>&1 || true)"
      if printf '%s\n' "$order_out" | grep -q 'CompositeDevice'; then
        echo "ORDER=set"
      else
        echo "ORDER=empty"
      fi
      info_out="$(inputplumber device 0 info 2>&1 || true)"
      printf '%s\n' "$info_out" | grep -E 'Source Devices|"/dev/' || echo "SOURCES=(device 0 info missing)"
      inputplumber device 0 targets list 2>&1 | grep -E 'deck-uhid|keyboard|mouse|xbox|touchpad|Id' || true
    fi
    local h name mask
    shopt -s nullglob
    for h in /sys/class/hidraw/hidraw*; do
      grep -q '000012FB' "$h/device/uevent" 2>/dev/null || continue
      name="$(basename "$h")"
      echo "DECK_HIDRAW=$name"
      stat -c 'DECK_MODE=%a %A' "/dev/$name" 2>/dev/null || true
      if command -v getfacl >/dev/null 2>&1; then
        getfacl -p "/dev/$name" 2>/dev/null | awk '/^(user:|mask:|other:)/ { print "DECK_ACL " $0 }'
      fi
    done
    shopt -u nullglob
    # Keyboard target the session can still read when the virtual pad cannot.
    # The event number changes across resume, so match the name.
    local evdev evname
    shopt -s nullglob
    for evdev in /sys/class/input/event*/device/name; do
      evname="$(tr -d '\n' <"$evdev" 2>/dev/null || true)"
      [[ "$evname" == "InputPlumber Keyboard" ]] || continue
      name="$(basename "$(dirname "$(dirname "$evdev")")")"
      echo "KEYBOARD_TARGET=$name"
      stat -c 'KEYBOARD_TARGET_MODE=%a %A' "/dev/input/$name" 2>/dev/null || true
      if command -v getfacl >/dev/null 2>&1; then
        getfacl -p "/dev/input/$name" 2>/dev/null | awk '/^(user:|mask:|other:)/ { print "KEYBOARD_TARGET_ACL " $0 }'
      fi
    done
    shopt -u nullglob
    echo "===== END SNAPSHOT ====="
  } >"$out" 2>&1
}

collect_logs() {
  local dir="$1"
  local lookback="${2:-}"
  local epoch since=""
  if [[ -n "$lookback" ]]; then
    since="$(date -d "$lookback" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  else
    epoch="$(cat "${dir}/pre.epoch" 2>/dev/null || true)"
    if [[ -n "$epoch" ]]; then
      since="$(date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$since" ]]; then
    since="$(date -d '15 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  fi

  journalctl -u inputplumber --since "$since" -o short-precise --no-pager \
    >"${dir}/journal-inputplumber.txt" 2>&1 || true
  journalctl -k --since "$since" -o short-precise \
    --grep='17[Ee][Ff]:61[Ee][Bb]|hid-lenovo|hidraw|uhid|Legion Controller' \
    --no-pager >"${dir}/journal-kernel.txt" 2>&1 || true
  publish_tree "$dir"
}

write_summary() {
  local dir="$1"
  local snap
  snap="$(ls -1t "$dir"/post-*.txt "$dir"/mark.txt "$dir"/snapshot.txt 2>/dev/null | head -1 || true)"
  [[ -n "$snap" ]] || snap="$(ls -1t "$dir"/*.txt 2>/dev/null | head -1 || true)"
  {
    echo "===== summary ====="
    echo "dir: $dir"
    echo "time: $(date -Is)"
    echo "snapshot used: ${snap:-none}"
    echo

    echo "----- signals -----"
    if [[ -n "$snap" && -f "$snap" ]]; then
      awk 'p && !/^===== END SNAPSHOT =====$/{print} /^----- signals -----$/{p=1}' "$snap"
    else
      echo "(no snapshot)"
    fi
    echo

    echo "----- when.txt -----"
    if [[ -f "${dir}/when.txt" ]]; then
      cat "${dir}/when.txt"
    else
      echo "(no when.txt)"
    fi
    echo
    echo "----- steam controller.txt (resume-relevant lines) -----"
    local steam_pad steam_ui
    shopt -s nullglob
    steam_pad=("${dir}"/steam-*-controller.txt "${dir}"/steam-*-controller.previous.txt)
    steam_ui=("${dir}"/steam-*-controller_ui.txt "${dir}"/steam-*-controller_ui.previous.txt)
    shopt -u nullglob
    if [[ ${#steam_pad[@]} -gt 0 ]]; then
      grep -n -E 'Unable to open|device opened|hid_read failure|PollState|Local Device Found|path: /dev/hidraw|disconnected|connected' \
        "${steam_pad[@]}" || echo "(no matching lines in tails)"
    else
      echo "(no steam controller tails yet)"
    fi
    echo
    echo "----- steam controller_ui.txt (connect/disconnect / focus) -----"
    if [[ ${#steam_ui[@]} -gt 0 ]]; then
      grep -n -E 'disconnected|connected|Guide button|OnFocusWindowChanged|Loaded Config' \
        "${steam_ui[@]}" || echo "(no matching lines in tails)"
    else
      echo "(no steam controller_ui tails yet)"
    fi
    echo

    echo "----- inputplumber journal flags -----"
    if [[ -f "${dir}/journal-inputplumber.txt" ]]; then
      grep -E 'Gamepad order|Resource busy|add_source_device|hid_read|No such device|Setting target devices|Unable to create initialized|Detected Legion' \
        "${dir}/journal-inputplumber.txt" || echo "(no matching lines)"
    else
      echo "(journal not collected yet)"
    fi
    echo
    echo "How to read this (reported bug: sticks work in Steam UI, dead inside the game):"
    echo "  Look for 'device opened' / 'Controller 15 connected' after resume."
    echo "  Then see if controller_ui reloads the game appid, or only the Steam UI."
    echo "  A '(deleted)' hidraw/js fd held by the game means it kept the pre-suspend device."
    echo "  'Unable to open' with Steam UI sticks still working would be a different failure."
    echo "===== END SUMMARY ====="
  } >"${dir}/summary.txt" 2>&1
  ln -sfn "${dir}/summary.txt" "${BASE_DIR}/LATEST-summary.txt"
}

cmd_snapshot() {
  ensure_dirs
  local dir out
  dir="$(new_cycle snapshot)"
  out="${dir}/snapshot.txt"
  date +%s >"${dir}/pre.epoch"
  note_event "$dir" snapshot
  write_snapshot "$out" "snapshot"
  copy_steam_tails "$dir" manual
  collect_logs "$dir" "20 minutes ago"
  write_summary "$dir"
  ok "Wrote $dir"
  log "Summary: ${dir}/summary.txt"
}

cmd_mark() {
  ensure_dirs
  local dir note="$*"
  dir="$(new_cycle mark)"
  date +%s >"${dir}/pre.epoch"
  note_event "$dir" mark
  if [[ -n "$note" ]]; then
    printf '%s\n' "$note" >"${dir}/NOTE.txt"
  fi
  write_snapshot "${dir}/mark.txt" "mark"
  copy_steam_tails "$dir" manual
  collect_logs "$dir" "20 minutes ago"
  write_summary "$dir"
  ok "Marked broken state: $dir"
  log "Summary: ${dir}/summary.txt"
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "Open-fd list was skipped. For holders: pkexec $0 mark"
  fi
}

# True if any process with comm matching the regex holds an open fd on $1.
# Root-only (needs /proc/*/fd). Returns 1 if not root or no match.
proc_holds_node() {
  local node="$1" comm_re="$2" pid comm link
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 1
  [[ -n "$node" ]] || return 1
  shopt -s nullglob
  for pid in /proc/[0-9]*; do
    comm="$(tr -d '\0' <"${pid}/comm" 2>/dev/null || true)"
    [[ "$comm" =~ $comm_re ]] || continue
    for link in "$pid"/fd/*; do
      [[ "$(readlink "$link" 2>/dev/null || true)" == "$node" ]] && { shopt -u nullglob; return 0; }
    done
  done
  shopt -u nullglob
  return 1
}

bounce_deck_uhid() {
  if ! command -v inputplumber >/dev/null 2>&1; then
    echo "bounce skipped: inputplumber not in PATH"
    return 1
  fi
  echo "bouncing deck-uhid targets (force Steam rediscovery)"
  if inputplumber device 0 targets set keyboard mouse >/dev/null 2>&1; then
    sleep 0.3
    if inputplumber device 0 targets set deck-uhid keyboard mouse >/dev/null 2>&1; then
      echo "targets set deck-uhid keyboard mouse"
      return 0
    fi
    echo "targets set deck-uhid failed; restoring"
    inputplumber device 0 targets set deck-uhid keyboard mouse >/dev/null 2>&1 || true
    return 1
  fi
  echo "targets set keyboard mouse failed (composite may be missing)"
  return 1
}

# Two post-resume breaks share this helper:
# H1 — deck-uhid hidraw (28de:12fb) stays mode 000; Steam logs Unable to open
#      and never creates "Microsoft X-Box 360 pad 0". Steam UI sticks die too.
# H2 — Steam opens hidraw OK; Proton misses IN_ATTRIB on the new 360 pad.
#
# Fix H1 first (ACL + bounce). Then touch the 360 pad for H2 (up to twice if
# Proton still has no open fd). USB can return late (21:49 hard fail): callers
# must keep invoking this on a wall-clock schedule, not only after snapshots.
repair_after_resume() {
  local dir="$1" tag="${2:-manual}"
  local log="${dir}/nudge.log"
  local h name node mode mask fixed=0 bounced=0 found_360=0 found_deck=0
  local ev base access group_read touch_count=0 want_bounce=0
  local bounced_marker="${dir}/.bounced-deck-uhid"
  local touch_count_file="${dir}/.touch-count-xinput360"
  local resume_epoch age=0 now
  resume_epoch="$(tr -d '\n' <"${dir}/resume.epoch" 2>/dev/null || true)"
  now="$(date +%s)"
  if [[ "$resume_epoch" =~ ^[0-9]+$ ]]; then
    age=$((now - resume_epoch))
    [[ "$age" -ge 0 ]] || age=0
  elif [[ "$tag" == manual ]]; then
    # Manual nudge: allow rediscovery bounce immediately.
    age=99
  fi
  {
    echo "===== repair ${tag} $(date -Is) age=${age}s ====="

    shopt -s nullglob
    for h in /sys/class/hidraw/hidraw*; do
      grep -q '000012FB' "$h/device/uevent" 2>/dev/null || continue
      found_deck=1
      name="$(basename "$h")"
      node="/dev/${name}"
      mode="$(stat -c '%a' "$node" 2>/dev/null || echo '?')"
      mask="$(getfacl -p "$node" 2>/dev/null | awk -F: '/^mask:/{print $3; exit}')"
      echo "deck_hidraw=${node} mode=${mode} mask=${mask:-?}"
      if [[ "$mode" == "0" || "$mode" == "000" || "$mask" == "---" ]]; then
        if chmod 0660 "$node" 2>/dev/null; then
          echo "chmod 0660 ${node}"
          fixed=1
          want_bounce=1
        else
          echo "chmod failed on ${node}"
        fi
        if command -v setfacl >/dev/null 2>&1; then
          setfacl -m u:deck:rw,m:rw "$node" 2>/dev/null && echo "setfacl u:deck:rw ${node}" || echo "setfacl failed"
        fi
        touch -c "$node" 2>/dev/null || true
        mode="$(stat -c '%a' "$node" 2>/dev/null || echo '?')"
        echo "deck_hidraw_after mode=${mode}"
      else
        echo "deck_hidraw already openable"
        # Steam does not retry after Unable to open. If the node is readable but
        # Steam still holds nothing after a few seconds, bounce once. Do not
        # bounce at age 0–2s — healthy resumes open hidraw around +2s.
        if proc_holds_node "$node" '^steam$'; then
          echo "steam holds ${node}"
        elif [[ "$age" -ge 3 ]]; then
          echo "steam not holding ${node} after ${age}s — queue rediscovery"
          want_bounce=1
        else
          echo "steam not holding ${node} yet (age=${age}s) — defer bounce"
        fi
      fi
    done
    [[ "$found_deck" -eq 1 ]] || echo "no deck-uhid hidraw 28de:12fb yet"

    # Only bounce once per cycle; skip if 360 pad already exists (Steam got far enough).
    for ev in /sys/class/input/event*/device/name; do
      name="$(tr -d '\n' <"$ev" 2>/dev/null || true)"
      if [[ "$name" == "Microsoft X-Box 360 pad 0" ]]; then
        found_360=1
        break
      fi
    done
    if [[ "$want_bounce" -eq 1 && "$found_360" -eq 0 ]]; then
      if [[ -e "$bounced_marker" ]]; then
        echo "skip bounce: already bounced this cycle"
      elif bounce_deck_uhid; then
        bounced=1
        : >"$bounced_marker"
        publish_tree "$bounced_marker"
      fi
    elif [[ "$want_bounce" -eq 1 && "$found_360" -eq 1 ]]; then
      echo "skip bounce: XInput 360 pad already present"
    fi

    # H2: IN_ATTRIB for Proton winebus. Up to 2 touches if winedevice still
    # has no fd (21:31 soft fail: one late touch was not enough / too early alone).
    [[ -r "$touch_count_file" ]] && touch_count="$(tr -d '\n' <"$touch_count_file" 2>/dev/null || echo 0)"
    [[ "$touch_count" =~ ^[0-9]+$ ]] || touch_count=0
    found_360=0
    for ev in /sys/class/input/event*/device/name; do
      name="$(tr -d '\n' <"$ev" 2>/dev/null || true)"
      [[ "$name" == "Microsoft X-Box 360 pad 0" ]] || continue
      found_360=1
      base="$(basename "$(dirname "$(dirname "$ev")")")"
      node="/dev/input/${base}"
      access="$(stat -c '%A' "$node" 2>/dev/null || echo '?')"
      group_read="${access:4:1}"
      echo "xinput360=${node} mode=${access} touches=${touch_count}"
      if proc_holds_node "$node" '^winedevice'; then
        echo "skip touch: winedevice already holds ${node}"
        continue
      fi
      if [[ "$touch_count" -ge 2 ]]; then
        echo "skip touch: already nudged ${touch_count} times this cycle"
        continue
      fi
      if [[ "$group_read" != "r" && "${access:7:1}" != "r" ]]; then
        echo "skip touch: not readable yet"
        continue
      fi
      if touch -c "$node"; then
        touch_count=$((touch_count + 1))
        printf '%s\n' "$touch_count" >"$touch_count_file"
        publish_tree "$touch_count_file"
        echo "touched ${node} (#${touch_count}, inotify IN_ATTRIB for Proton winebus)"
      else
        echo "touch failed on ${node}"
      fi
    done
    shopt -u nullglob

    [[ "$found_360" -eq 1 ]] || echo "no Microsoft X-Box 360 pad 0"
    echo "fixed_acl=${fixed} bounced=${bounced} xinput360=${found_360} touches=${touch_count}"
  } >>"$log" 2>&1
  publish_tree "$log"
  logger -t legion-go2-resume-gamepad "repair ${tag} fixed=${fixed} bounce=${bounced} ${dir}"
}

# Wall-clock repair ticks. Independent of heavy snapshots so t+2s is ~2s after
# resume (21:49: Steam hit sealed hidraw at +2s; old schedule drifted to +30s).
repair_loop_wallclock() {
  local dir="$1" resume_epoch="$2" t now delay
  for t in 1 2 3 5 8 12 20 30 45 60; do
    now="$(date +%s)"
    delay=$((resume_epoch + t - now))
    if [[ "$delay" -gt 0 ]]; then
      sleep "$delay"
    fi
    repair_after_resume "$dir" "t+${t}s" || true
  done
}

snapshot_loop_post() {
  local dir="$1" resume_epoch="$2" now delay
  # post-0s already written in on_post before fork.
  now="$(date +%s)"
  delay=$((resume_epoch + 5 - now))
  [[ "$delay" -gt 0 ]] && sleep "$delay"
  write_snapshot "${dir}/post-5s.txt" "post-5s" || true
  publish_tree "$dir"
  now="$(date +%s)"
  delay=$((resume_epoch + 15 - now))
  [[ "$delay" -gt 0 ]] && sleep "$delay"
  write_snapshot "${dir}/post-15s.txt" "post-15s" || true
  copy_steam_tails "$dir" post-15s
  collect_logs "$dir"
  write_summary "$dir"
  publish_tree "$dir"
  logger -t legion-go2-resume-gamepad "cycle complete ${dir}"
}

on_pre() {
  local dir
  dir="$(new_cycle suspend)"
  date +%s >"${dir}/pre.epoch"
  note_event "$dir" suspend
  copy_steam_tails "$dir" pre
  write_snapshot "${dir}/pre.txt" "pre"
  publish_tree "$dir"
  logger -t legion-go2-resume-gamepad "pre snapshot ${dir}"
}

on_post() {
  local dir resume_epoch
  dir="$(cat "${STATE_DIR}/active-cycle" 2>/dev/null || true)"
  if [[ -z "$dir" || ! -d "$dir" ]]; then
    dir="$(new_cycle resume-only)"
    date +%s >"${dir}/pre.epoch"
  fi
  resume_epoch="$(date +%s)"
  printf '%s\n' "$resume_epoch" >"${dir}/resume.epoch"
  publish_tree "${dir}/resume.epoch"

  # Immediate repair + steam tails, then fork repair and snapshots apart.
  # Heavy post-0s dump must not delay the wall-clock repair loop.
  note_event "$dir" resume
  repair_after_resume "$dir" "t+0s"
  copy_steam_tails "$dir" post-0s
  logger -t legion-go2-resume-gamepad "post-0s-repair ${dir}"

  repair_loop_wallclock "$dir" "$resume_epoch" &
  (
    write_snapshot "${dir}/post-0s.txt" "post-0s" || true
    publish_tree "$dir"
    logger -t legion-go2-resume-gamepad "post-0s ${dir}"
    snapshot_loop_post "$dir" "$resume_epoch"
  ) &
}

cmd_watch() {
  ensure_dirs
  mkdir -p "$(dirname "$LOCK_FILE")"
  exec 9>>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "Another watch is already running ($LOCK_FILE)."
    exit 1
  fi
  if ! command -v busctl >/dev/null 2>&1; then
    warn "busctl is required to listen for PrepareForSleep."
    exit 1
  fi
  log "Watching PrepareForSleep. Dumps → ${CYCLE_ROOT}"
  log "Leave this running across the suspend you care about. Ctrl-C stops it."
  local pending=0 line
  # stdbuf keeps signals from sitting in a pipe buffer until the next one.
  stdbuf -oL busctl --system monitor \
    --match "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" \
    | while IFS= read -r line; do
        case "$line" in
          *Member=PrepareForSleep*) pending=1 ;;
          *BOOLEAN\ true*)
            [[ "$pending" -eq 1 ]] || continue
            pending=0
            on_pre || true
            ;;
          *BOOLEAN\ false*)
            [[ "$pending" -eq 1 ]] || continue
            pending=0
            on_post || true
            ;;
        esac
      done
}

install_unit() {
  need_root install
  local src
  src="$(script_path)"
  cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Legion Go 2 resume gamepad trace (suspend/resume dumps only)
After=systemd-logind.service
# Do not delay or block suspend.

[Service]
Type=simple
Environment=DECK_HOME=/home/deck
ExecStart="${src}" watch
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT_PATH"
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
  ok "Installed and started $UNIT_NAME"
  ok "Dumps: ${BASE_DIR} (also after you return to Desktop)"
  log "Remove with: $src uninstall"
}

uninstall_unit() {
  need_root uninstall
  systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  ok "Removed $UNIT_NAME (logs under ${BASE_DIR} kept)"
}

cmd_find() {
  local q="$*"
  ensure_dirs
  if [[ -z "$q" ]]; then
    log "Recent index lines (local time, event, cycle dir):"
    tail -n 40 "$INDEX_FILE" 2>/dev/null || log "(index empty — no suspend captured yet)"
    return 0
  fi
  log "Looking up resume/suspend time: $q"
  log "Use the cycle whose 'resume' time is closest. Do not assume LATEST is the bad one."
  if [[ -f "$INDEX_FILE" ]]; then
    grep -F -- "$q" "$INDEX_FILE" || log "(no index line contains '$q')"
  else
    log "(no index yet)"
  fi
  local w dir
  shopt -s nullglob
  for w in "$CYCLE_ROOT"/cycle-*/when.txt; do
    grep -F -q -- "$q" "$w" || continue
    dir="$(dirname "$w")"
    echo
    echo "===== $dir ====="
    cat "$w"
    if [[ -f "${dir}/summary.txt" ]]; then
      echo "summary: ${dir}/summary.txt"
    else
      echo "summary: (not written yet — resume may still be inside the 15s window)"
    fi
  done
  shopt -u nullglob
}

cmd_status() {
  log "Script: $(script_path)"
  log "Dumps:  ${BASE_DIR}"
  if [[ -f "$UNIT_PATH" ]]; then
    log "Unit file: present ($UNIT_PATH)"
  else
    log "Unit file: not installed"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    log "Service: $(systemctl is-active "$UNIT_NAME" 2>&1 || true) / $(systemctl is-enabled "$UNIT_NAME" 2>&1 || true)"
  fi
  if [[ -L "${BASE_DIR}/LATEST" || -d "${BASE_DIR}/LATEST" ]]; then
    log "Latest cycle: $(readlink -f "${BASE_DIR}/LATEST" 2>/dev/null || echo "${BASE_DIR}/LATEST")"
    [[ -f "${BASE_DIR}/LATEST-summary.txt" ]] && log "Latest summary: ${BASE_DIR}/LATEST-summary.txt"
  else
    log "Latest cycle: (none yet)"
  fi
  log ""
  log "Recent cycles:"
  ls -1dt "$CYCLE_ROOT"/cycle-* 2>/dev/null | head -8 || log "(none)"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

  snapshot          dump controller paths now
  mark [note]       extra dump; not required if the service is installed
  watch             listen for suspend/resume and write pre, +0s, +5s, +15s
  install           install a boot service that runs watch (pkexec)
  uninstall         remove that service (pkexec); keeps dumps
  find [HH:MM]      show the cycle for that local time (24h). No arg: recent index
  status            show service and latest dump
  nudge             run repair once now (agent/Desktop; log in manual-nudge/)
  help              this text

Dumps: ${BASE_DIR}/cycles/cycle-*/  (last ${KEEP_CYCLES} kept)
Index: ${INDEX_FILE}
Game Mode → Desktop does not delete cycles. Look up by the resume clock time.
EOF
}

main() {
  local cmd="${1:-snapshot}"
  shift || true
  case "$cmd" in
    snapshot|"") cmd_snapshot ;;
    mark) cmd_mark "$@" ;;
    watch) cmd_watch ;;
    install) install_unit ;;
    uninstall) uninstall_unit ;;
    status) cmd_status ;;
    find) cmd_find "$@" ;;
    nudge)
      ensure_dirs
      mkdir -p "${BASE_DIR}/manual-nudge"
      repair_after_resume "${BASE_DIR}/manual-nudge" "manual"
      ok "Repair log: ${BASE_DIR}/manual-nudge/nudge.log"
      ;;
    help|-h|--help) usage ;;
    *)
      warn "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
