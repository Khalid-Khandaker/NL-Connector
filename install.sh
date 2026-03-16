#!/usr/bin/env bash
set -euo pipefail

WINDOWS_IP="${WINDOWS_IP:-}"
SHARE_NAME="${SHARE_NAME:-NiceLabelIn}"

MOUNT_POINT="/mnt/nicelabel/in"

BASE="/opt/nl-connector"
APP_DIR="$BASE/app"
CFG_DIR="$BASE/config"
LOG_DIR="/var/log/nl-connector"

VENV="$APP_DIR/.venv"

CONNECTOR_NAME="nl-connector"
CONNECTOR_SERVICE="/etc/systemd/system/${CONNECTOR_NAME}.service"
CONNECTOR_TIMER="/etc/systemd/system/${CONNECTOR_NAME}.timer"

SELECTOR_NAME="selector"
SELECTOR_SERVICE="/etc/systemd/system/${SELECTOR_NAME}.service"
SELECTOR_TIMER="/etc/systemd/system/${SELECTOR_NAME}.timer"

CLEANUP_NAME="cleanup-retention"
CLEANUP_SERVICE="/etc/systemd/system/${CLEANUP_NAME}.service"
CLEANUP_TIMER="/etc/systemd/system/${CLEANUP_NAME}.timer"

CONTROL_API_NAME="connector-control-api"
CONTROL_API_SERVICE="/etc/systemd/system/${CONTROL_API_NAME}.service"

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo ./install.sh"
  fi
}

check_required_files() {
  [ -f "./app/connector.py" ] || die "Missing ./app/connector.py"
  [ -f "./app/selector.py" ] || die "Missing ./app/selector.py"
  [ -f "./app/cleanup_retention.sh" ] || die "Missing ./app/cleanup_retention.sh"
  [ -f "./config/config.env" ] || die "Missing ./config/config.env (copy from template)"
  [ -f "./config/smb-credentials" ] || die "Missing ./config/smb-credentials (copy from template)"
  [ -f "./systemd/nl-connector.service" ] || die "Missing ./systemd/nl-connector.service"
  [ -f "./systemd/nl-connector.timer" ] || die "Missing ./systemd/nl-connector.timer"
  [ -f "./systemd/selector.service" ] || die "Missing ./systemd/selector.service"
  [ -f "./systemd/selector.timer" ] || die "Missing ./systemd/selector.timer"
  [ -f "./systemd/cleanup-retention.service" ] || die "Missing ./systemd/cleanup-retention.service"
  [ -f "./systemd/cleanup-retention.timer" ] || die "Missing ./systemd/cleanup-retention.timer"
  [ -f "./app/control_api.py" ] || die "Missing ./app/control_api.py"
  [ -f "./systemd/connector-control-api.service" ] || die "Missing ./systemd/connector-control-api.service"
  [ -f "./app/apply_schedule.sh" ] || die "Missing ./app/apply_schedule.sh"
}

preflight_checks() {
  echo "Running preflight checks..."

  command -v systemctl >/dev/null 2>&1 || die "systemd not available (systemctl missing)"
  command -v python3 >/dev/null 2>&1 || die "python3 not installed"

  [ -n "$WINDOWS_IP" ] || die "WINDOWS_IP not set. Example: sudo WINDOWS_IP=192.168.254.103 ./install.sh"
  [ -n "$SHARE_NAME" ] || die "SHARE_NAME empty (default is NiceLabelIn)"

  mkdir -p /opt/.nlconnector_preflight_test 2>/dev/null || die "Cannot write to /opt"
  rmdir /opt/.nlconnector_preflight_test 2>/dev/null || true

  mkdir -p /var/log/.nlconnector_preflight_test 2>/dev/null || die "Cannot write to /var/log"
  rmdir /var/log/.nlconnector_preflight_test 2>/dev/null || true

  [ -r "./config/config.env" ] || die "config/config.env not readable"
  [ -r "./config/smb-credentials" ] || die "config/smb-credentials not readable"

  echo "Preflight checks passed."
}

create_user_if_needed() {
  if id nlconnector >/dev/null 2>&1; then
    echo "OK: user nlconnector exists"
  else
    echo "Creating service user: nlconnector"
    useradd -r -s /usr/sbin/nologin nlconnector
  fi
}

install_deps() {
  echo "Installing OS dependencies..."
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip cifs-utils unixodbc curl ca-certificates gnupg lsb-release

  echo "Installing Microsoft ODBC Driver 18 for SQL Server..."
  . /etc/os-release
  UBUNTU_VER="${VERSION_ID}"

  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg

  cat > /etc/apt/sources.list.d/mssql-release.list <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${UBUNTU_VER}/prod ${VERSION_CODENAME} main
EOF

  apt-get update -y
  ACCEPT_EULA=Y apt-get install -y msodbcsql18

}

create_dirs() {
  echo "Creating directories..."
  mkdir -p "$APP_DIR" "$CFG_DIR" "$BASE/staging" "$BASE/archive" "$BASE/error" "$LOG_DIR" "$(dirname "$MOUNT_POINT")"

  touch "$LOG_DIR/cleanup.log"

  chown -R nlconnector:nlconnector "$APP_DIR" "$BASE/staging" "$BASE/archive" "$BASE/error"
  chown -R nlconnector:nlconnector "$LOG_DIR"

  chown nlconnector:nlconnector "$LOG_DIR/cleanup.log"
  chmod 640 "$LOG_DIR/cleanup.log"

  chmod 755 "$LOG_DIR"

  chmod 755 "$BASE" "$APP_DIR" "$CFG_DIR"
}

install_app_files() {
  echo "Installing app files..."
  install -m 755 ./app/connector.py "$APP_DIR/connector.py"
  install -m 755 ./app/selector.py "$APP_DIR/selector.py"
  install -m 755 ./app/cleanup_retention.sh "$APP_DIR/cleanup_retention.sh"

  install -m 755 ./app/control_api.py "$APP_DIR/control_api.py"
  chown nlconnector:nlconnector "$APP_DIR/control_api.py" || true

  install -m 755 ./app/apply_schedule.sh "$APP_DIR/apply_schedule.sh"
  chown nlconnector:nlconnector "$APP_DIR/apply_schedule.sh" || true

  if [ -f "./app/requirements.txt" ]; then
    install -m 644 ./app/requirements.txt "$APP_DIR/requirements.txt"
  fi
  chown nlconnector:nlconnector "$APP_DIR/connector.py" "$APP_DIR/selector.py" "$APP_DIR/cleanup_retention.sh" || true
  [ -f "$APP_DIR/requirements.txt" ] && chown nlconnector:nlconnector "$APP_DIR/requirements.txt" || true
}

install_config_files() {
  echo "Installing config files..."
  install -m 640 ./config/config.env "$CFG_DIR/.env"
  install -m 640 ./config/smb-credentials "$CFG_DIR/smb-credentials"
  chown root:nlconnector "$CFG_DIR/.env" "$CFG_DIR/smb-credentials"
}

setup_venv() {
  echo "Creating venv..."
  if [ ! -d "$VENV" ]; then
    sudo -u nlconnector python3 -m venv "$VENV"
  fi

  echo "Installing Python deps..."
  sudo -u nlconnector "$VENV/bin/pip" install --upgrade pip

  if [ -f "$APP_DIR/requirements.txt" ]; then
    sudo -u nlconnector "$VENV/bin/pip" install -r "$APP_DIR/requirements.txt"
  else
    sudo -u nlconnector "$VENV/bin/pip" install supabase python-dotenv pyodbc flask requests
  fi
}

setup_mount() {
  echo "Setting up SMB mount..."

  local USER_UID USER_GID
  USER_UID="$(id -u nlconnector)"
  USER_GID="$(id -g nlconnector)"

  local FSTAB_LINE="//${WINDOWS_IP}/${SHARE_NAME} ${MOUNT_POINT} cifs credentials=${CFG_DIR}/smb-credentials,uid=${USER_UID},gid=${USER_GID},iocharset=utf8,vers=3.0,file_mode=0664,dir_mode=0775,nounix 0 0"

  echo "Cleaning old mount state if present..."

  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "Unmounting existing mount at $MOUNT_POINT ..."
    umount -f "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
  fi

  mkdir -p "$(dirname "$MOUNT_POINT")"
  mkdir -p "$MOUNT_POINT"

  echo "Refreshing fstab entry for $MOUNT_POINT ..."
  if [ -f /etc/fstab ]; then
    cp /etc/fstab /etc/fstab.bak.nlconnector.$(date +%Y%m%d%H%M%S)
    grep -vE "^[[:space:]]*//[^[:space:]]+[[:space:]]+${MOUNT_POINT}[[:space:]]+cifs([[:space:]]|$)" /etc/fstab > /etc/fstab.tmp || true
    mv /etc/fstab.tmp /etc/fstab
  fi

  echo "Adding new fstab entry..."
  echo "$FSTAB_LINE" >> /etc/fstab

  systemctl daemon-reload || true

  echo "Mounting $MOUNT_POINT ..."
  mount "$MOUNT_POINT"

  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$MOUNT_POINT" || die "Mount failed for $MOUNT_POINT (check share + creds)."
  fi

  echo "Testing write access to SMB mount..."
  sudo -u nlconnector touch "${MOUNT_POINT}/_nlconnector_write_test.txt" || die "nlconnector cannot write to ${MOUNT_POINT}. Check Windows share + NTFS permissions."
}

install_systemd_units() {
  echo "Installing systemd unit files..."
  install -m 644 ./systemd/nl-connector.service "$CONNECTOR_SERVICE"
  install -m 644 ./systemd/nl-connector.timer "$CONNECTOR_TIMER"
  install -m 644 ./systemd/selector.service "$SELECTOR_SERVICE"
  install -m 644 ./systemd/selector.timer "$SELECTOR_TIMER"
  install -m 644 ./systemd/cleanup-retention.service "$CLEANUP_SERVICE"
  install -m 644 ./systemd/cleanup-retention.timer "$CLEANUP_TIMER"
  install -m 644 ./systemd/connector-control-api.service "$CONTROL_API_SERVICE"

  echo "Normalizing unit files to Unix line endings..."
  sed -i 's/\r$//' \
    "$CONNECTOR_SERVICE" \
    "$CONNECTOR_TIMER" \
    "$SELECTOR_SERVICE" \
    "$SELECTOR_TIMER" \
    "$CLEANUP_SERVICE" \
    "$CLEANUP_TIMER" \
    "$CONTROL_API_SERVICE"

  echo "Removing old cron retention job if present..."
  rm -f /etc/cron.daily/nl-connector-retention

  systemctl daemon-reload
}

final_checks() {
  echo "Final checks..."
  systemctl status "${CONNECTOR_NAME}.timer" --no-pager || true
  systemctl status "${SELECTOR_NAME}.timer" --no-pager || true
  systemctl status "${CLEANUP_NAME}.timer" --no-pager || true

  echo "Verifying venv + deps..."
  sudo -u nlconnector "$VENV/bin/python" -c "import supabase, dotenv, pyodbc, flask; print('deps OK')" || true

  echo "DONE."
  echo "Logs: $LOG_DIR/connector.log"
  echo "Cleanup log: $LOG_DIR/cleanup.log"
  echo "Mount: $MOUNT_POINT"
  echo "Tip: run a manual test with:"
  echo "  sudo systemctl start ${SELECTOR_NAME}.service"
  echo "  sudo systemctl start ${CONNECTOR_NAME}.service"
  echo "  sudo systemctl start ${CLEANUP_NAME}.service"
}

main() {
  need_root
  check_required_files
  preflight_checks
  install_deps
  create_user_if_needed
  create_dirs
  install_app_files
  install_config_files
  setup_venv
  setup_mount
  install_systemd_units
  echo "Applying schedules from config..."
  "$APP_DIR/apply_schedule.sh"
  final_checks
}

main
