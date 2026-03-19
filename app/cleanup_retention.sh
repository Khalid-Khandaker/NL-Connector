#!/usr/bin/env bash
set -euo pipefail

REQUIRED_USER="nlconnector"
CURRENT_USER="$(id -un)"

if [ "$CURRENT_USER" != "$REQUIRED_USER" ]; then
  echo "ERROR: cleanup_retention.sh must run as '$REQUIRED_USER', not '$CURRENT_USER'." >&2
  exit 1
fi

CFG="/opt/nl-connector/config/.env"

RETENTION_DAYS=30

if [ -f "$CFG" ]; then
  set -a
  . "$CFG"
  set +a
  RETENTION_DAYS="${CLEANUP_RETENTION_DAYS:-30}"
fi

ERROR_DIR="/opt/nl-connector/error"
ARCHIVE_DIR="/opt/nl-connector/archive"

LOG_DIR="/var/log/nl-connector"
LOG_FILE="$LOG_DIR/cleanup.log"

mkdir -p "$LOG_DIR"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

echo "$(ts) cleanup started retention_days=$RETENTION_DAYS" >> "$LOG_FILE"

cleanup_dir() {
  local target_dir="$1"
  local label="$2"

  if [ ! -d "$target_dir" ]; then
    echo "$(ts) $label skipped dir_missing=$target_dir" >> "$LOG_FILE"
    return 0
  fi

  # count candidates first (folders older than retention)
  local count
  count=$(find "$target_dir" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" | wc -l | tr -d ' ')

  if [ "$count" = "0" ]; then
    echo "$(ts) $label nothing_to_delete dir=$target_dir" >> "$LOG_FILE"
    return 0
  fi

  echo "$(ts) $label deleting count=$count dir=$target_dir" >> "$LOG_FILE"

  # delete
  find "$target_dir" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -mtime +"$RETENTION_DAYS" \
    -exec rm -rf {} + >> "$LOG_FILE" 2>&1

  echo "$(ts) $label deleted count=$count dir=$target_dir" >> "$LOG_FILE"
}

cleanup_dir "$ERROR_DIR" "error"
cleanup_dir "$ARCHIVE_DIR" "archive"

echo "$(ts) cleanup completed" >> "$LOG_FILE"
