#!/usr/bin/env bash
set -euo pipefail

CFG="/opt/nl-connector/config/.env"


SELECTOR_DROPIN_DIR="/etc/systemd/system/selector.service.d"
SELECTOR_TRIGGER_DROPIN="${SELECTOR_DROPIN_DIR}/trigger-connector.conf"
SELECTOR_TIMER="/etc/systemd/system/selector.timer"
CONNECTOR_TIMER="/etc/systemd/system/nl-connector.timer"
CLEANUP_TIMER="/etc/systemd/system/cleanup-retention.timer"

write_selector_trigger_dropin() {
  mkdir -p "$SELECTOR_DROPIN_DIR"
  cat > "$SELECTOR_TRIGGER_DROPIN" <<EOF
[Unit]
OnSuccess=nl-connector.service
EOF
}

remove_selector_trigger_dropin() {
  rm -f "$SELECTOR_TRIGGER_DROPIN"
  rmdir "$SELECTOR_DROPIN_DIR" 2>/dev/null || true
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo /opt/nl-connector/app/apply_schedule.sh"
  fi
}

require_file() {
  [ -f "$1" ] || die "Missing required file: $1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_valid_time_hhmm() {
  local t="$1"
  [[ "$t" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]
}

is_valid_interval() {
  local v="$1"
  [[ "$v" =~ ^[1-9][0-9]*(s|m|h)$ ]]
}

normalize_interval_for_systemd() {
  local v="$1"
  case "$v" in
    *s) echo "${v%s}" ;;
    *m) echo "${v%m}min" ;;
    *h) echo "${v%h}h" ;;
    *) die "Invalid interval: $v" ;;
  esac
}

build_oncalendar_lines() {
  local raw="$1"
  local unit_name="$2"
  local seen=""
  local out=()

  IFS=',' read -ra parts <<< "$raw"
  [ "${#parts[@]}" -gt 0 ] || die "$unit_name times are empty"

  for p in "${parts[@]}"; do
    local t
    t="$(trim "$p")"
    [ -n "$t" ] || continue

    is_valid_time_hhmm "$t" || die "Invalid time '$t' in $unit_name. Use HH:MM, example 06:30"

    case ",$seen," in
      *,"$t",*) continue ;;
      *) seen="${seen:+$seen,}$t" ;;
    esac

    out+=("OnCalendar=*-*-* ${t}:00")
  done

  [ "${#out[@]}" -gt 0 ] || die "No valid times found for $unit_name"
  printf '%s\n' "${out[@]}"
}

write_selector_timer() {
  local lines="$1"
  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Run Selector Service'
    printf '\n'
    printf '%s\n' '[Timer]'
    printf '%s\n' "$lines"
    printf '%s\n' 'Persistent=true'
    printf '%s\n' 'RandomizedDelaySec=30s'
    printf '%s\n' 'Unit=selector.service'
    printf '\n'
    printf '%s\n' '[Install]'
    printf '%s\n' 'WantedBy=timers.target'
  } > "$SELECTOR_TIMER"
}

write_cleanup_timer() {
  local lines="$1"
  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Run NiceLabel Cleanup Retention Daily'
    printf '\n'
    printf '%s\n' '[Timer]'
    printf '%s\n' "$lines"
    printf '%s\n' 'Persistent=true'
    printf '%s\n' 'RandomizedDelaySec=30s'
    printf '%s\n' 'Unit=cleanup-retention.service'
    printf '\n'
    printf '%s\n' '[Install]'
    printf '%s\n' 'WantedBy=timers.target'
  } > "$CLEANUP_TIMER"
}

write_connector_timer_interval() {
  local interval="$1"

  cat > "$CONNECTOR_TIMER" <<EOF
[Unit]
Description=Run NiceLabel Connector

[Timer]
OnBootSec=15
OnUnitActiveSec=${interval}
AccuracySec=1s
Unit=nl-connector.service

[Install]
WantedBy=timers.target
EOF
}

write_connector_timer_schedule() {
  local lines="$1"
  {
    printf '%s\n' '[Unit]'
    printf '%s\n' 'Description=Run NiceLabel Connector'
    printf '\n'
    printf '%s\n' '[Timer]'
    printf '%s\n' "$lines"
    printf '%s\n' 'Persistent=true'
    printf '%s\n' 'RandomizedDelaySec=30s'
    printf '%s\n' 'Unit=nl-connector.service'
    printf '\n'
    printf '%s\n' '[Install]'
    printf '%s\n' 'WantedBy=timers.target'
  } > "$CONNECTOR_TIMER"
}

main() {
  need_root
  require_file "$CFG"

  # shellcheck disable=SC1090
  set -a
  . "$CFG"
  set +a

  : "${CLEANUP_RETENTION_DAYS:=30}"
  : "${CLEANUP_TIMES:=06:30}"
  : "${SELECTOR_TIMES:=06:00}"
  : "${CONNECTOR_MODE:=interval}"
  : "${CONNECTOR_INTERVAL:=2s}"
  : "${CONNECTOR_TIMES:=06:05}"
  : "${CONNECTOR_TRIGGER_AFTER_SELECTOR:=false}"

  case "$CONNECTOR_TRIGGER_AFTER_SELECTOR" in
    true|false) ;;
    *) die "CONNECTOR_TRIGGER_AFTER_SELECTOR must be 'true' or 'false'" ;;
  esac

  [[ "$CLEANUP_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || die "CLEANUP_RETENTION_DAYS must be a positive integer"

  local cleanup_lines
  cleanup_lines="$(build_oncalendar_lines "$CLEANUP_TIMES" "CLEANUP_TIMES")"

  local selector_lines
  selector_lines="$(build_oncalendar_lines "$SELECTOR_TIMES" "SELECTOR_TIMES")"

  write_cleanup_timer "$cleanup_lines"
  write_selector_timer "$selector_lines"

  case "$CONNECTOR_MODE" in
    interval)
      is_valid_interval "$CONNECTOR_INTERVAL" || die "Invalid CONNECTOR_INTERVAL '$CONNECTOR_INTERVAL'. Examples: 2s, 10s, 1m, 1h"
      write_connector_timer_interval "$(normalize_interval_for_systemd "$CONNECTOR_INTERVAL")"
      ;;
    schedule)
      local connector_lines
      connector_lines="$(build_oncalendar_lines "$CONNECTOR_TIMES" "CONNECTOR_TIMES")"
      write_connector_timer_schedule "$connector_lines"
      ;;
    *)
      die "CONNECTOR_MODE must be either 'interval' or 'schedule'"
      ;;
  esac

  chmod 644 "$SELECTOR_TIMER" "$CONNECTOR_TIMER" "$CLEANUP_TIMER"

  if [ "$CONNECTOR_TRIGGER_AFTER_SELECTOR" = "true" ]; then
    write_selector_trigger_dropin
  else
    remove_selector_trigger_dropin
  fi

  systemctl daemon-reload

  systemd-analyze verify "$SELECTOR_TIMER"
  systemd-analyze verify "$CONNECTOR_TIMER"
  systemd-analyze verify "$CLEANUP_TIMER"

  systemctl enable --now selector.timer
  systemctl enable --now nl-connector.timer
  systemctl enable --now cleanup-retention.timer

  systemctl restart selector.timer
  systemctl restart nl-connector.timer
  systemctl restart cleanup-retention.timer

  echo "Schedules applied successfully."
  echo
  echo "Current config:"
  echo "  CLEANUP_RETENTION_DAYS=$CLEANUP_RETENTION_DAYS"
  echo "  CLEANUP_TIMES=$CLEANUP_TIMES"
  echo "  SELECTOR_TIMES=$SELECTOR_TIMES"
  echo "  CONNECTOR_MODE=$CONNECTOR_MODE"
  if [ "$CONNECTOR_MODE" = "interval" ]; then
    echo "  CONNECTOR_INTERVAL=$CONNECTOR_INTERVAL"
  else
    echo "  CONNECTOR_TIMES=$CONNECTOR_TIMES"
  fi
  echo "  CONNECTOR_TRIGGER_AFTER_SELECTOR=$CONNECTOR_TRIGGER_AFTER_SELECTOR"
  echo
  systemctl list-timers --all | grep -E 'selector|nl-connector|cleanup-retention' || true
}

main "$@"
