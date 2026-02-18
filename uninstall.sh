#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/nl-connector"
LOG_DIR="/var/log/nl-connector"
MOUNT_POINT="/mnt/nicelabel/in"

CONNECTOR_NAME="nl-connector"
SELECTOR_NAME="nl-selector"

CONNECTOR_SERVICE="/etc/systemd/system/${CONNECTOR_NAME}.service"
CONNECTOR_TIMER="/etc/systemd/system/${CONNECTOR_NAME}.timer"

SELECTOR_SERVICE="/etc/systemd/system/${SELECTOR_NAME}.service"
SELECTOR_TIMER="/etc/systemd/system/${SELECTOR_NAME}.timer"

CRON_FILE="/etc/cron.daily/nl-connector-retention"

# Optional: remove service user too (default off)
REMOVE_USER="${REMOVE_USER:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo ./uninstall.sh"
  fi
}

stop_disable_units() {
  echo "Stopping/disabling systemd timers/services..."

  systemctl stop "${CONNECTOR_NAME}.timer" 2>/dev/null || true
  systemctl stop "${SELECTOR_NAME}.timer" 2>/dev/null || true

  systemctl disable "${CONNECTOR_NAME}.timer" 2>/dev/null || true
  systemctl disable "${SELECTOR_NAME}.timer" 2>/dev/null || true

  systemctl stop "${CONNECTOR_NAME}.service" 2>/dev/null || true
  systemctl stop "${SELECTOR_NAME}.service" 2>/dev/null || true

  systemctl disable "${CONNECTOR_NAME}.service" 2>/dev/null || true
  systemctl disable "${SELECTOR_NAME}.service" 2>/dev/null || true
}

remove_units() {
  echo "Removing systemd unit files..."

  rm -f "$CONNECTOR_SERVICE" "$CONNECTOR_TIMER" "$SELECTOR_SERVICE" "$SELECTOR_TIMER" || true

  systemctl daemon-reload || true
  systemctl reset-failed || true
}

remove_cron() {
  echo "Removing retention cron..."
  rm -f "$CRON_FILE" || true
}

remove_fstab_mount() {
  echo "Unmounting SMB mount and removing /etc/fstab entry..."

  umount -f "$MOUNT_POINT" 2>/dev/null || true

  if [ -f /etc/fstab ]; then
    # remove any CIFS entry that targets the mount point
    tmp="$(mktemp)"
    awk -v mp="$MOUNT_POINT" '
      # keep lines that do NOT match " <mp> cifs "
      !($0 ~ ("[[:space:]]" mp "[[:space:]]+cifs[[:space:]]"))
    ' /etc/fstab > "$tmp"
    cat "$tmp" > /etc/fstab
    rm -f "$tmp"
  fi

  # remove mountpoint directory if empty
  rmdir "$MOUNT_POINT" 2>/dev/null || true
}

remove_files() {
  echo "Removing connector directories/files..."

  rm -rf "$BASE" || true
  rm -rf "$LOG_DIR" || true

  # remove parent dir if empty
  rmdir /var/log/nl-connector 2>/dev/null || true
}

maybe_remove_user() {
  if [ "$REMOVE_USER" = "1" ]; then
    echo "Removing user nlconnector..."
    userdel nlconnector 2>/dev/null || true
  else
    echo "Keeping user nlconnector (set REMOVE_USER=1 to remove it)."
  fi
}

main() {
  need_root

  stop_disable_units
  remove_units
  remove_cron
  remove_fstab_mount
  remove_files
  maybe_remove_user

  echo "DONE: nl-connector removed."
}

main
