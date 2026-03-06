#!/usr/bin/env bash
set -euo pipefail

REMOVE_USER="${REMOVE_USER:-0}"
REMOVE_PACKAGES="${REMOVE_PACKAGES:-0}"

MOUNT_POINT="/mnt/nicelabel/in"
MOUNT_PARENT="/mnt/nicelabel"

BASE="/opt/nl-connector"
APP_DIR="$BASE/app"
CFG_DIR="$BASE/config"
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

MSSQL_REPO_FILE="/etc/apt/sources.list.d/mssql-release.list"
MSSQL_KEYRING="/usr/share/keyrings/microsoft.gpg"

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

  # Control API is manual-start in install flow, but remove safely if present/running
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
  # install.sh created this file during mount test
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

remove_repo_files() {
  echo "Removing Microsoft SQL repo files..."
  rm -f "$MSSQL_REPO_FILE"
  rm -f "$MSSQL_KEYRING"
  apt-get update -y || true
}

remove_packages_if_requested() {
  if [ "$REMOVE_PACKAGES" != "1" ]; then
    echo "Skipping package removal (set REMOVE_PACKAGES=1 to remove install-added packages)."
    return 0
  fi

  echo "Removing packages installed by install.sh..."
  apt-get remove -y msodbcsql18 || true

  # Only remove these if you are comfortable affecting the machine globally.
  # They may have been used by other apps too.
  apt-get remove -y cifs-utils unixodbc python3-venv python3-pip || true

  apt-get autoremove -y || true
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
  echo
  echo "Optional removals:"
  echo "  REMOVE_USER=$REMOVE_USER"
  echo "  REMOVE_PACKAGES=$REMOVE_PACKAGES"
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
  remove_repo_files
  remove_packages_if_requested
  remove_user_if_requested
  final_message
}

main
