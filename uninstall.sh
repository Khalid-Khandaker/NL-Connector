#!/usr/bin/env bash
set -euo pipefail

# Default behavior:
# - remove connector files/folders
# - remove systemd units
# - remove cron entry
# - unmount SMB share
# - remove connector fstab entry
# - remove mount folders if empty
# - remove nlconnector service user
#
# This script does NOT remove Ubuntu packages, Python packages,
# SQL drivers, cifs-utils, unixodbc, or Microsoft repo files.

REMOVE_USER="${REMOVE_USER:-1}"

MOUNT_POINT="/mnt/nicelabel/in"
MOUNT_PARENT="/mnt/nicelabel"

BASE="/opt/nl-connector"
LOG_DIR="/var/log/nl-connector"

CONNECTOR_NAME="nl-connector"
CONNECTOR_SERVICE="/etc/systemd/system/${CONNECTOR_NAME}.service"
CONNECTOR_TIMER="/etc/systemd/system/${CONNECTOR_NAME}.timer"

SELECTOR_NAME="selector"
SELECTOR_SERVICE="/etc/systemd/system/${SELECTOR_NAME}.service"
SELECTOR_TIMER="/etc/systemd/system/${SELECTOR_NAME}.timer"

CONTROL_API_NAME="connector-control-api"
CONTROL_API_SERVICE="/etc/systemd/system/${CONTROL_API_NAME}.service"

RETENTION_CRON="/etc/cron.daily/nl-connector-retention"

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo ./uninstall.sh"
  fi
}

stop_disable_units() {
  echo "Stopping and disabling services/timers..."

  systemctl stop "${CONNECTOR_NAME}.timer" 2>/dev/null || true
  systemctl disable "${CONNECTOR_NAME}.timer" 2>/dev/null || true

  systemctl stop "${CONNECTOR_NAME}.service" 2>/dev/null || true
  systemctl disable "${CONNECTOR_NAME}.service" 2>/dev/null || true

  systemctl stop "${SELECTOR_NAME}.timer" 2>/dev/null || true
  systemctl disable "${SELECTOR_NAME}.timer" 2>/dev/null || true

  systemctl stop "${SELECTOR_NAME}.service" 2>/dev/null || true
  systemctl disable "${SELECTOR_NAME}.service" 2>/dev/null || true

  systemctl stop "${CONTROL_API_NAME}.service" 2>/dev/null || true
  systemctl disable "${CONTROL_API_NAME}.service" 2>/dev/null || true
}

remove_systemd_units() {
  echo "Removing systemd unit files..."
  rm -f "$CONNECTOR_SERVICE" "$CONNECTOR_TIMER"
  rm -f "$SELECTOR_SERVICE" "$SELECTOR_TIMER"
  rm -f "$CONTROL_API_SERVICE"

  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

remove_cron() {
  echo "Removing retention cron..."
  rm -f "$RETENTION_CRON"
}

remove_windows_test_file_if_mounted() {
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Removing SMB write test file if present..."
    rm -f "${MOUNT_POINT}/_nlconnector_write_test.txt" 2>/dev/null || true
  fi
}

unmount_share() {
  echo "Unmounting SMB share..."
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    umount -f "$MOUNT_POINT" 2>/dev/null || true
  fi
}

remove_fstab_entry() {
  echo "Removing fstab entry for ${MOUNT_POINT}..."
  if [ -f /etc/fstab ]; then
    cp /etc/fstab /etc/fstab.bak.nlconnector.$(date +%Y%m%d%H%M%S)
    grep -vE "[[:space:]]${MOUNT_POINT}[[:space:]]+cifs[[:space:]]" /etc/fstab > /etc/fstab.tmp
    mv /etc/fstab.tmp /etc/fstab
  fi
}

remove_app_files() {
  echo "Removing application directories..."
  rm -rf "$BASE"
}

remove_logs() {
  echo "Removing log directory..."
  rm -rf "$LOG_DIR"
}

remove_mount_dirs_if_empty() {
  echo "Cleaning mount folders if empty..."
  rmdir "$MOUNT_POINT" 2>/dev/null || true
  rmdir "$MOUNT_PARENT" 2>/dev/null || true
}

remove_user_if_requested() {
  if [ "$REMOVE_USER" != "1" ]; then
    echo "Keeping service user 'nlconnector' (set REMOVE_USER=1 to remove it)."
    return 0
  fi

  if id nlconnector >/dev/null 2>&1; then
    echo "Removing service user nlconnector..."
    userdel nlconnector 2>/dev/null || true
  fi
}

final_message() {
  echo
  echo "Uninstall complete."
  echo "Removed:"
  echo "  - /opt/nl-connector"
  echo "  - /var/log/nl-connector"
  echo "  - systemd units for connector, selector, and control API"
  echo "  - retention cron file"
  echo "  - SMB mount entry for $MOUNT_POINT"
  echo "  - mount folders if they became empty"
  echo "  - nlconnector user (default behavior)"
  echo
  echo "Kept on the machine:"
  echo "  - Ubuntu packages and dependencies"
  echo "  - Microsoft SQL ODBC driver and repo files"
  echo "  - cifs-utils, unixodbc, python3-pip, python3-venv"
  echo
  echo "Recommended checks:"
  echo "  systemctl status ${CONNECTOR_NAME}.timer || true"
  echo "  systemctl status ${SELECTOR_NAME}.timer || true"
  echo "  systemctl status ${CONTROL_API_NAME}.service || true"
  echo "  mount | grep nicelabel || true"
  echo "  grep nicelabel /etc/fstab || true"
}

main() {
  need_root
  stop_disable_units
  remove_windows_test_file_if_mounted
  unmount_share
  remove_fstab_entry
  remove_cron
  remove_systemd_units
  remove_app_files
  remove_logs
  remove_mount_dirs_if_empty
  remove_user_if_requested
  final_message
}

main
