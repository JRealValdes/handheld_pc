#!/usr/bin/env bash
# Legion Go 2 suspend/wake: optional settle mitigation + on-demand diagnostics.
#
# Default install is settle-only (no per-suspend dumps). Use --debug when hunting
# a recurrence. See KNOWLEDGE.md.
#
# Usage:
#   ./debug-legion-go2-suspend.sh              # dump + postmortem check
#   ./debug-legion-go2-suspend.sh dump
#   ./debug-legion-go2-suspend.sh install-hook           # settle only (default)
#   ./debug-legion-go2-suspend.sh install-hook --debug   # settle + pre/post dumps
#   ./debug-legion-go2-suspend.sh uninstall-hook
#   ./debug-legion-go2-suspend.sh postmortem
#   ./debug-legion-go2-suspend.sh status

set -u

LOG_DIR="/var/log/legion-go2-suspend"
# SteamOS systemd-sleep only executes /usr/lib/systemd/system-sleep (not /etc).
HOOK_PATH="/usr/lib/systemd/system-sleep/legion-go2-suspend-debug"
LEGACY_HOOK_PATH="/etc/systemd/system-sleep/legion-go2-suspend-debug"
DECK_HOME="${DECK_HOME:-${HOME:-/home/deck}}"
FALLBACK_DIR="${DECK_HOME}/legion-go2-suspend-debug"
# Provisional settle before PM suspend entry (milliseconds). Hypothesis: race.
SETTLE_MS="${SETTLE_MS:-1000}"
# install-hook mode: settle (default) | debug
HOOK_MODE="${HOOK_MODE:-settle}"

ERRORS=()
WARNINGS=()

log()  { printf '%s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; WARNINGS+=("$*"); }
fail() { printf '[FAIL] %s\n' "$*" >&2; ERRORS+=("$*"); }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v pkexec >/dev/null 2>&1; then
      exec pkexec env DECK_HOME="${DECK_HOME}" bash "$0" "$@"
    fi
    fail "Must run as root (pkexec/sudo not available)."
    exit 1
  fi
}

ensure_log_dir() {
  if mkdir -p "$LOG_DIR" 2>/dev/null; then
    chmod 755 "$LOG_DIR" 2>/dev/null || true
    printf '%s' "$LOG_DIR"
    return 0
  fi
  if mkdir -p "$FALLBACK_DIR" 2>/dev/null; then
    warn "Could not use $LOG_DIR; using $FALLBACK_DIR"
    printf '%s' "$FALLBACK_DIR"
    return 0
  fi
  local tmp="${TMPDIR:-/tmp}/legion-go2-suspend-debug"
  mkdir -p "$tmp"
  warn "Could not use $LOG_DIR or $FALLBACK_DIR; using $tmp"
  printf '%s' "$tmp"
}

stamp() { date +%Y%m%d-%H%M%S; }

write_dump_body() {
  local tag="${1:-manual}"
  echo "===== Legion Go 2 suspend debug ($tag) ====="
  echo "time: $(date -Is)"
  echo "host: $(hostname 2>/dev/null || true)"
  echo

  echo "----- versions -----"
  if [[ -r /etc/os-release ]]; then
    grep -E '^(NAME|PRETTY_NAME|VERSION_ID|BUILD_ID|VARIANT_ID|STEAMOS_DEFAULT_UPDATE_BRANCH)=' /etc/os-release || cat /etc/os-release
  fi
  command -v steamos-version >/dev/null 2>&1 && steamos-version || true
  uname -a
  echo

  echo "----- power / sleep sysfs -----"
  for f in /sys/power/state /sys/power/mem_sleep /sys/power/disk /sys/power/wakeup_count; do
    [[ -r "$f" ]] && printf '%s=%s\n' "$f" "$(tr -d '\n' <"$f" 2>/dev/null || true)"
  done
  echo

  echo "----- ACPI / DMI -----"
  if [[ -d /sys/class/dmi/id ]]; then
    for f in sys_vendor product_name product_version product_sku board_name bios_version bios_date; do
      [[ -r "/sys/class/dmi/id/$f" ]] && printf '%s=%s\n' "$f" "$(tr -d '\n' <"/sys/class/dmi/id/$f")"
    done
  fi
  journalctl -b -k -o short-precise --grep='s2idle quirk|Low-power S0|ACPI: PM:' -n 30 --no-pager 2>/dev/null || true
  echo

  echo "----- systemd-inhibit -----"
  systemd-inhibit --list 2>/dev/null || true
  echo

  echo "----- logind -----"
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Docked 2>/dev/null || true
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager IdleHint 2>/dev/null || true
  busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager PreparingForSleep 2>/dev/null || true
  echo

  echo "----- active wake sources (enabled) -----"
  local ws count=0
  shopt -s nullglob
  for ws in /sys/class/wakeup/wakeup*; do
    local name en
    name="$(basename "$ws")"
    en="$(tr -d '\n' <"$ws/enable" 2>/dev/null || echo '?')"
    [[ "$en" == "enabled" ]] || continue
    printf '  %s enable=%s event_count=%s wakeup_count=%s name=%s\n' \
      "$name" "$en" \
      "$(tr -d '\n' <"$ws/event_count" 2>/dev/null || echo '?')" \
      "$(tr -d '\n' <"$ws/wakeup_count" 2>/dev/null || echo '?')" \
      "$(tr -d '\n' <"$ws/name" 2>/dev/null || echo '?')"
    count=$((count + 1))
  done
  shopt -u nullglob
  echo "(enabled wake sources listed: $count)"
  echo

  echo "----- network / power services (brief) -----"
  systemctl is-active NetworkManager iwd bluetooth inputplumber steamos-manager 2>/dev/null || true
  echo

  echo "----- recent suspend/resume journal (this boot, last 80 matches) -----"
  journalctl -b -o short-precise --grep='PM: suspend|System Suspend|Preparing for sleep|Power key|s2idle|Sleeping system|suspend entry|suspend exit|Operation .suspend' -n 80 --no-pager 2>/dev/null || true
  echo

  echo "----- last kernel suspend lines (this boot) -----"
  journalctl -b -k -o short-precise --grep='PM: suspend|s2idle|Freezing|thaw' -n 40 --no-pager 2>/dev/null || true
  echo

  echo "===== END DUMP ====="
}

cmd_dump() {
  local tag="${1:-manual}"
  local dir out
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    dir="$(ensure_log_dir)"
  else
    if mkdir -p "$FALLBACK_DIR" 2>/dev/null; then
      dir="$FALLBACK_DIR"
    else
      dir="$(ensure_log_dir)"
    fi
  fi
  out="${dir}/dump-${tag}-$(stamp).txt"
  write_dump_body "$tag" >"$out" 2>&1
  ok "Wrote $out" >&2
  printf '%s\n' "$out"
}

install_hook_file() {
  need_root "$@"

  local mode="${HOOK_MODE:-settle}"
  case "${1:-}" in
    --debug|debug) mode=debug; shift || true ;;
    --settle|settle) mode=settle; shift || true ;;
  esac

  # /usr is usually read-only on SteamOS; unlock if needed.
  if command -v steamos-readonly >/dev/null 2>&1; then
    if steamos-readonly status 2>/dev/null | grep -qi 'enabled'; then
      log "==> steamos-readonly disable (needed to install under /usr/lib)"
      steamos-readonly disable || warn "steamos-readonly disable failed"
    fi
  fi

  mkdir -p "$(dirname "$HOOK_PATH")"

  # Remove inert /etc copy from earlier installs (SteamOS systemd-sleep ignores it).
  if [[ -e "$LEGACY_HOOK_PATH" ]]; then
    rm -f "$LEGACY_HOOK_PATH"
    ok "Removed inert legacy hook: $LEGACY_HOOK_PATH"
  fi

  if [[ "$mode" == "debug" ]]; then
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"
    mkdir -p "$FALLBACK_DIR"
    chmod 777 "$FALLBACK_DIR" 2>/dev/null || true
    _install_debug_hook
  else
    _install_settle_only_hook
  fi

  sed -i "s/^SETTLE_MS=.*/SETTLE_MS=${SETTLE_MS}/" "$HOOK_PATH"
  if ! chmod 755 "$HOOK_PATH"; then
    fail "Could not write $HOOK_PATH (is /usr writable? try: steamos-readonly disable)"
    exit 1
  fi
  ok "Installed sleep hook: $HOOK_PATH (mode=$mode)"
  ok "Provisional settle: ${SETTLE_MS}ms before suspend entry"
  if [[ "$mode" == "debug" ]]; then
    ok "Debug dumps enabled → $LOG_DIR and $FALLBACK_DIR"
    log "After a stuck suspend + hard power-off, run: $0 postmortem"
  else
    ok "Debug dumps disabled (settle only). Re-enable with: $0 install-hook --debug"
  fi
}

_install_settle_only_hook() {
  cat >"$HOOK_PATH" <<'HOOK'
#!/bin/bash
# Auto-installed by debug-legion-go2-suspend.sh — settle only (no dumps).
# Must live in /usr/lib/systemd/system-sleep/ on SteamOS (not /etc).
SETTLE_MS=1000
phase="${1:-unknown}"
action="${2:-unknown}"
if [ "$phase" = "pre" ] && [ "$action" = "suspend" ]; then
  settle_sec="$(awk -v ms="$SETTLE_MS" 'BEGIN { printf "%.3f", ms/1000 }')"
  logger -t legion-go2-suspend "settle ${settle_sec}s before suspend entry"
  sleep "$settle_sec" 2>/dev/null || sleep 1
  logger -t legion-go2-suspend "settle done"
fi
HOOK
}

_install_debug_hook() {
  cat >"$HOOK_PATH" <<'HOOK'
#!/bin/bash
# Auto-installed by debug-legion-go2-suspend.sh
# - pre: dump evidence, then wait SETTLE_MS (provisional race settle)
# - post: dump evidence after resume
# Must live in /usr/lib/systemd/system-sleep/ on SteamOS (not /etc).
LOG_DIR="/var/log/legion-go2-suspend"
HOME_DIR="/home/deck/legion-go2-suspend-debug"
SETTLE_MS=1000
mkdir -p "$LOG_DIR" 2>/dev/null || true
mkdir -p "$HOME_DIR" 2>/dev/null || true

phase="${1:-unknown}"
action="${2:-unknown}"
ts="$(date +%Y%m%d-%H%M%S)"
base="${phase}-${action}-${ts}.txt"
tmp="$(mktemp /tmp/legion-go2-suspend.XXXXXX 2>/dev/null || echo /tmp/legion-go2-suspend.$$)"

logger -t legion-go2-suspend "hook ${phase}/${action} starting settle_ms=${SETTLE_MS}"

{
  echo "===== systemd-sleep hook ====="
  echo "time: $(date -Is)"
  echo "phase: $phase"
  echo "action: $action"
  echo "argv: $*"
  echo "uid: $(id -u 2>/dev/null)"
  echo "uptime: $(tr -d '\n' </proc/uptime 2>/dev/null)"
  echo "settle_ms: $SETTLE_MS"
  echo

  echo "----- /sys/power -----"
  for f in /sys/power/state /sys/power/mem_sleep /sys/power/wakeup_count; do
    [ -r "$f" ] && printf '%s=%s\n' "$f" "$(tr -d '\n' <"$f" 2>/dev/null)"
  done
  echo

  echo "----- systemd-inhibit -----"
  systemd-inhibit --list 2>/dev/null || true
  echo

  if [ "$phase" = "pre" ]; then
    echo "----- steam / games (best-effort) -----"
    pgrep -a steam 2>/dev/null | head -5 || true
    ls /run/user/1000/systemd/transient/app-steam-app* 2>/dev/null | head -20 || true
    echo

    echo "----- lsusb (Lenovo/Valve) -----"
    lsusb 2>/dev/null | grep -Ei '17ef|28de|Lenovo|Valve' || lsusb 2>/dev/null | head -20 || true
    echo

    echo "----- power/wakeup=enabled (bounded 2s) -----"
    timeout 2 find /sys/devices -path '*/power/wakeup' 2>/dev/null | while read -r f; do
      v="$(tr -d '\n' <"$f" 2>/dev/null || true)"
      [ "$v" = "enabled" ] || continue
      printf '  %s\n' "$f"
    done
    echo

    echo "----- wakeup class (active_count>0 or event_count>0) -----"
    for ws in /sys/class/wakeup/wakeup*; do
      [ -e "$ws/name" ] || continue
      ac="$(tr -d '\n' <"$ws/active_count" 2>/dev/null || echo 0)"
      ec="$(tr -d '\n' <"$ws/event_count" 2>/dev/null || echo 0)"
      [ "$ac" = "0" ] && [ "$ec" = "0" ] && continue
      printf '  %s name=%s active_count=%s event_count=%s wakeup_count=%s prevent_ms=%s\n' \
        "$(basename "$ws")" \
        "$(tr -d '\n' <"$ws/name" 2>/dev/null)" \
        "$ac" "$ec" \
        "$(tr -d '\n' <"$ws/wakeup_count" 2>/dev/null || echo '?')" \
        "$(tr -d '\n' <"$ws/prevent_suspend_time_ms" 2>/dev/null || echo '?')"
    done
    echo

    echo "----- marker -----"
    echo "PRE_SUSPEND_DUMP_OK $(date -Is)"
  fi

  if [ "$phase" = "post" ]; then
    echo "----- marker -----"
    echo "POST_RESUME_DUMP_OK $(date -Is)"
    echo
    echo "----- last PM lines -----"
    journalctl -b -k -o short-precise --grep='PM: suspend' -n 20 --no-pager 2>/dev/null || true
  fi
} >"$tmp" 2>&1 || true

out="${LOG_DIR}/${base}"
out_home="${HOME_DIR}/${base}"
cp -f "$tmp" "$out" 2>/dev/null || true
cp -f "$tmp" "$out_home" 2>/dev/null || true
chown deck:deck "$out_home" 2>/dev/null || true
rm -f "$tmp" 2>/dev/null || true

echo "$(date -Is) $phase $action -> ${out} / ${out_home}" >>"${LOG_DIR}/hook-trail.log" 2>/dev/null || true
echo "$(date -Is) $phase $action -> ${out} / ${out_home}" >>"${HOME_DIR}/hook-trail.log" 2>/dev/null || true
logger -t legion-go2-suspend "hook ${phase}/${action} wrote ${out_home}"

if [ "$phase" = "pre" ] && [ "$action" = "suspend" ]; then
  settle_sec="$(awk -v ms="$SETTLE_MS" 'BEGIN { printf "%.3f", ms/1000 }')"
  logger -t legion-go2-suspend "settle ${settle_sec}s before suspend entry"
  sleep "$settle_sec" 2>/dev/null || sleep 1
  logger -t legion-go2-suspend "settle done"
fi
HOOK
}

uninstall_hook_file() {
  need_root "$@"
  if command -v steamos-readonly >/dev/null 2>&1; then
    if steamos-readonly status 2>/dev/null | grep -qi 'enabled'; then
      steamos-readonly disable || true
    fi
  fi
  if [[ -e "$HOOK_PATH" ]]; then
    rm -f "$HOOK_PATH"
    ok "Removed $HOOK_PATH"
  else
    warn "No hook at $HOOK_PATH"
  fi
  if [[ -e "$LEGACY_HOOK_PATH" ]]; then
    rm -f "$LEGACY_HOOK_PATH"
    ok "Removed legacy $LEGACY_HOOK_PATH"
  fi
}

cmd_status() {
  log "SteamOS / kernel:"
  grep -E '^(VERSION_ID|BUILD_ID)=' /etc/os-release 2>/dev/null || true
  uname -r
  log ""
  log "mem_sleep: $(tr -d '\n' </sys/power/mem_sleep 2>/dev/null || echo '?')"
  log "hook: $([[ -x "$HOOK_PATH" ]] && echo "installed ($HOOK_PATH)" || echo "not installed")"
  if [[ -x "$HOOK_PATH" ]]; then
    log "settle_ms: $(grep -E '^SETTLE_MS=' "$HOOK_PATH" 2>/dev/null | head -1 || echo '?')"
    if grep -q 'PRE_SUSPEND_DUMP' "$HOOK_PATH" 2>/dev/null; then
      log "hook_mode: debug (dumps on each suspend)"
    else
      log "hook_mode: settle-only (no dumps)"
    fi
  fi
  log "log dir: $LOG_DIR $([[ -d "$LOG_DIR" ]] && echo "(exists)" || echo "(missing)")"
  if [[ -d "$LOG_DIR" ]]; then
    log "recent dumps:"
    ls -lt "$LOG_DIR" 2>/dev/null | head -12 || true
  fi
  log ""
  log "This-boot suspend markers:"
  journalctl -b -k -o short-precise --grep='PM: suspend (entry|exit)' --no-pager 2>/dev/null | tail -20 || true
}

# Return 0 if this boot's last PM suspend line is an entry (no matching exit after).
boot_looks_stuck() {
  local boot="$1"
  local last
  last="$(journalctl -b "$boot" -k -o cat --grep='PM: suspend (entry|exit)' --no-pager 2>/dev/null | tail -1 || true)"
  [[ -n "$last" && "$last" == *"suspend entry"* ]]
}

cmd_postmortem() {
  local dir out
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    dir="$(ensure_log_dir)"
  elif mkdir -p "$FALLBACK_DIR" 2>/dev/null; then
    dir="$FALLBACK_DIR"
  else
    dir="$(ensure_log_dir)"
  fi
  out="${dir}/postmortem-$(stamp).txt"

  {
    echo "===== Legion Go 2 suspend postmortem ====="
    echo "time: $(date -Is)"
    echo

    echo "----- boots (journalctl --list-boots) -----"
    journalctl --list-boots --no-pager 2>/dev/null | head -20 || true
    echo

    echo "----- unclean suspend candidates (entry without matching exit) -----"
    local line boot_idx boot_id
    while read -r line; do
      # Example: " -1 9818ae2e... Tue 2026-08-04 ..."
      boot_idx="$(awk '{print $1}' <<<"$line")"
      boot_id="$(awk '{print $2}' <<<"$line")"
      [[ -n "$boot_idx" && "$boot_idx" =~ ^-?[0-9]+$ ]] || continue
      if boot_looks_stuck "$boot_idx"; then
        echo "*** STUCK CANDIDATE boot $boot_idx ($boot_id) ***"
        journalctl -b "$boot_idx" -o short-precise --grep='Power key|The system will suspend|System Suspend|PM: suspend|Successfully froze|s2idle' --no-pager 2>/dev/null | tail -40
        echo
        echo "--- last 30 lines of that boot ---"
        journalctl -b "$boot_idx" -o short-precise -n 30 --no-pager 2>/dev/null || true
        echo
      else
        echo "boot $boot_idx: clean or no unclean suspend (last PM line is not entry)"
      fi
    done < <(journalctl --list-boots --no-pager 2>/dev/null | head -8)
    echo

    echo "----- hook trail / pre dumps on disk -----"
    for d in "$LOG_DIR" "$FALLBACK_DIR"; do
      echo "== $d =="
      if [[ -d "$d" ]]; then
        ls -la "$d" 2>/dev/null || true
        echo
        if [[ -f "$d/hook-trail.log" ]]; then
          echo "hook-trail.log (tail):"
          tail -40 "$d/hook-trail.log" || true
          echo
        fi
      else
        echo "(missing)"
        echo
      fi
    done
    echo "Most recent pre-* dump (if any):"
    local latest
    latest="$(ls -t "$LOG_DIR"/pre-* "$FALLBACK_DIR"/pre-* 2>/dev/null | head -1 || true)"
    if [[ -n "${latest:-}" ]]; then
      echo "file: $latest"
      cat "$latest"
    else
      echo "(none — reinstall hook under /usr/lib and reproduce once)"
    fi
    echo

    echo "----- current baseline versions -----"
    grep -E '^(VERSION_ID|BUILD_ID)=' /etc/os-release 2>/dev/null || true
    uname -a
    echo "===== END POSTMORTEM ====="
  } >"$out" 2>&1

  ok "Wrote $out" >&2
  # Also print a short console summary
  {
    log ""
    log "Summary of unclean boots (also in the file):"
    grep -E '^\*\*\* STUCK|boot .*: clean' "$out" || true
    log ""
    log "Full postmortem: $out"
  } >&2
  printf '%s\n' "$out"
}

cmd_all() {
  log "Legion Go 2 suspend debug"
  log "No fix applied — capture only (see KNOWLEDGE.md)"
  log ""
  cmd_status
  log ""
  local dump_path pm_path
  dump_path="$(cmd_dump "baseline" | tail -1)"
  log ""
  pm_path="$(cmd_postmortem | tail -1)"
  log ""
  if [[ ! -x "$HOOK_PATH" ]]; then
    log "Tip: optional settle-only hook (no dumps): $0 install-hook"
    log "     debug dumps + settle when hunting:   $0 install-hook --debug"
  else
    ok "Sleep hook already installed"
    if grep -q 'settle only' "$HOOK_PATH" 2>/dev/null || ! grep -q 'PRE_SUSPEND_DUMP' "$HOOK_PATH" 2>/dev/null; then
      log "Mode: settle-only (no per-suspend dumps)"
    else
      log "Mode: debug dumps enabled"
    fi
  fi
  log ""
  log "Artifacts:"
  [[ -n "$dump_path" ]] && log "  dump: $dump_path"
  [[ -n "$pm_path" ]] && log "  postmortem: $pm_path"
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    log ""
    log "Warnings:"
    printf ' - %s\n' "${WARNINGS[@]}"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

  (default)       status + baseline dump + postmortem
  dump            write a one-shot state dump
  install-hook [--settle|--debug]
                  install /usr/lib systemd-sleep hook (pkexec)
                  default/--settle: 1s delay only (no dumps)
                  --debug:          dumps + settle (for recurrence hunts)
  uninstall-hook  remove that hook (pkexec)
  postmortem      scan prior boots for suspend entry without exit
  status          short status
  help            this text

Dumps (debug mode / manual): $LOG_DIR and ~/legion-go2-suspend-debug
Hook path (SteamOS): $HOOK_PATH
SETTLE_MS default ${SETTLE_MS} (override: SETTLE_MS=1500 $0 install-hook)
EOF
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    all|"")
      cmd_all
      ;;
    dump)
      shift || true
      cmd_dump "${1:-manual}"
      ;;
    install-hook)
      shift || true
      install_hook_file "$@"
      ;;
    uninstall-hook)
      uninstall_hook_file "$@"
      ;;
    postmortem)
      cmd_postmortem
      ;;
    status)
      cmd_status
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      fail "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
