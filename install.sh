#!/usr/bin/env bash
set -euo pipefail

WINDOWS_HOST="${WINDOWS_HOST:-}"
SHARE_NAME="${SHARE_NAME:-}"
MOUNT_POINT="${MOUNT_POINT:-}"

BASE="/opt/nl-connector"
APP_DIR="$BASE/app"
CFG_DIR="$BASE/config"
LOG_DIR="/var/log/nl-connector"

VENV="$APP_DIR/.venv"
SERVICE_USER="nlconnector"
SERVICE_GROUP="nlconnector"

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

WRAPPER_DIR="/usr/local/bin"
WRAP_CONNECTOR="${WRAPPER_DIR}/nl-connector-run"
WRAP_SELECTOR="${WRAPPER_DIR}/nl-selector-run"
WRAP_CONTROL_API="${WRAPPER_DIR}/nl-control-api-run"
WRAP_APPLY_SCHEDULE="${WRAPPER_DIR}/nl-connector-apply-schedule"
WRAP_UPDATE_SHARE="${WRAPPER_DIR}/nl-connector-update-share"

SUDOERS_UPDATE_SHARE="/etc/sudoers.d/nlconnector-update-share"

die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo ./install.sh"
  fi
}

validate_config_env() {
  local cfg_file="./config/config.env"
  [ -f "$cfg_file" ] || die "Missing ./config/config.env"
  [ -r "$cfg_file" ] || die "config/config.env not readable"

  local cfg_host=""
  local cfg_share=""
  local cfg_mount=""

  cfg_host="$(grep -E '^WINDOWS_HOST=' "$cfg_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  cfg_share="$(grep -E '^SHARE_NAME=' "$cfg_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  cfg_mount="$(grep -E '^MOUNT_POINT=' "$cfg_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"

  if [ -z "$WINDOWS_HOST" ] && [ -z "$cfg_host" ]; then
    die "WINDOWS_HOST not set. Define it in config/config.env or pass it in terminal."
  fi

  if [ -z "$SHARE_NAME" ] && [ -z "$cfg_share" ]; then
    die "SHARE_NAME not set. Define it in config/config.env or pass it in terminal."
  fi

  if [ -z "$MOUNT_POINT" ] && [ -z "$cfg_mount" ]; then
    die "MOUNT_POINT not set. Define it in config/config.env or pass it in terminal."
  fi
}

validate_smb_credentials() {
  local smb_file="./config/smb-credentials"
  [ -f "$smb_file" ] || die "Missing ./config/smb-credentials"
  [ -r "$smb_file" ] || die "config/smb-credentials not readable"

  local smb_user=""
  local smb_pass=""
  local smb_domain=""

  smb_user="$(grep -E '^username=' "$smb_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  smb_pass="$(grep -E '^password=' "$smb_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  smb_domain="$(grep -E '^domain=' "$smb_file" | head -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"

  [ -n "$smb_user" ] || die "config/smb-credentials invalid: username is missing or empty"
  [ -n "$smb_pass" ] || die "config/smb-credentials invalid: password is missing or empty"

  if [ -z "$smb_domain" ]; then
    echo "WARN: smb-credentials domain is empty. This is OK for workgroup setups but may fail in Active Directory environments."
  fi
}

check_required_files() {
  [ -f "./app/connector.py" ] || die "Missing ./app/connector.py"
  [ -f "./app/selector.py" ] || die "Missing ./app/selector.py"
  [ -f "./app/control_api.py" ] || die "Missing ./app/control_api.py"
  [ -f "./app/cleanup_retention.sh" ] || die "Missing ./app/cleanup_retention.sh"
  [ -f "./app/apply_schedule.sh" ] || die "Missing ./app/apply_schedule.sh"
  [ -f "./app/update_share.sh" ] || die "Missing ./app/update_share.sh"

  [ -f "./config/config.env" ] || die "Missing ./config/config.env (copy from template)"
  [ -f "./config/smb-credentials" ] || die "Missing ./config/smb-credentials (copy from template)"

  [ -f "./systemd/nl-connector.service" ] || die "Missing ./systemd/nl-connector.service"
  [ -f "./systemd/nl-connector.timer" ] || die "Missing ./systemd/nl-connector.timer"
  [ -f "./systemd/selector.service" ] || die "Missing ./systemd/selector.service"
  [ -f "./systemd/selector.timer" ] || die "Missing ./systemd/selector.timer"
  [ -f "./systemd/cleanup-retention.service" ] || die "Missing ./systemd/cleanup-retention.service"
  [ -f "./systemd/cleanup-retention.timer" ] || die "Missing ./systemd/cleanup-retention.timer"
}

load_mount_config() {
  [ -f "./config/config.env" ] || die "Missing ./config/config.env"

  local cfg_host=""
  local cfg_share=""
  local cfg_mount=""

  cfg_host="$(grep -E '^WINDOWS_HOST=' ./config/config.env | head -n1 | cut -d= -f2- || true)"
  cfg_share="$(grep -E '^SHARE_NAME=' ./config/config.env | head -n1 | cut -d= -f2- || true)"
  cfg_mount="$(grep -E '^MOUNT_POINT=' ./config/config.env | head -n1 | cut -d= -f2- || true)"

  WINDOWS_HOST="${WINDOWS_HOST:-$cfg_host}"
  SHARE_NAME="${SHARE_NAME:-$cfg_share}"
  MOUNT_POINT="${MOUNT_POINT:-$cfg_mount}"
}

preflight_checks() {
  echo "Running preflight checks..."

  command -v systemctl >/dev/null 2>&1 || die "systemd not available (systemctl missing)"
  command -v python3 >/dev/null 2>&1 || die "python3 not installed"
  command -v visudo >/dev/null 2>&1 || die "visudo not installed"

  [ -n "$WINDOWS_HOST" ] || die "WINDOWS_HOST not set. Define it in config/config.env or pass it in terminal."
  [ -n "$SHARE_NAME" ] || die "SHARE_NAME not set. Define it in config/config.env or pass it in terminal."
  [ -n "$MOUNT_POINT" ] || die "MOUNT_POINT not set. Define it in config/config.env or pass it in terminal."

  mkdir -p /opt/.nlconnector_preflight_test 2>/dev/null || die "Cannot write to /opt"
  rmdir /opt/.nlconnector_preflight_test 2>/dev/null || true

  mkdir -p /var/log/.nlconnector_preflight_test 2>/dev/null || die "Cannot write to /var/log"
  rmdir /var/log/.nlconnector_preflight_test 2>/dev/null || true

  echo "Preflight checks passed."
}

create_user_if_needed() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    echo "OK: user $SERVICE_USER exists"
  else
    echo "Creating service user: $SERVICE_USER"
    useradd -r -s /usr/sbin/nologin "$SERVICE_USER"
  fi
}

install_deps() {
  echo "Installing OS dependencies..."
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip cifs-utils unixodbc curl ca-certificates gnupg lsb-release sudo

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
  mkdir -p "$BASE" "$APP_DIR" "$CFG_DIR" "$BASE/staging" "$BASE/archive" "$BASE/error" "$LOG_DIR" "$(dirname "$MOUNT_POINT")"

  touch "$LOG_DIR/cleanup.log"

  chown root:root "$BASE" "$APP_DIR" "$CFG_DIR"
  chmod 755 "$BASE" "$APP_DIR" "$CFG_DIR"

  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$BASE/staging" "$BASE/archive" "$BASE/error"
  chmod 755 "$BASE/staging" "$BASE/archive" "$BASE/error"

  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
  chmod 755 "$LOG_DIR"

  chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR/cleanup.log"
  chmod 640 "$LOG_DIR/cleanup.log"
}

install_app_files() {
  echo "Installing app files..."
  install -m 755 ./app/connector.py "$APP_DIR/connector.py"
  install -m 755 ./app/selector.py "$APP_DIR/selector.py"
  install -m 755 ./app/control_api.py "$APP_DIR/control_api.py"
  install -m 755 ./app/cleanup_retention.sh "$APP_DIR/cleanup_retention.sh"
  install -m 755 ./app/apply_schedule.sh "$APP_DIR/apply_schedule.sh"
  install -m 755 ./app/update_share.sh "$APP_DIR/update_share.sh"

  if [ -f "./app/requirements.txt" ]; then
    install -m 644 ./app/requirements.txt "$APP_DIR/requirements.txt"
  fi

  chown root:root \
    "$APP_DIR/connector.py" \
    "$APP_DIR/selector.py" \
    "$APP_DIR/control_api.py" \
    "$APP_DIR/cleanup_retention.sh" \
    "$APP_DIR/apply_schedule.sh" \
    "$APP_DIR/update_share.sh"

  if [ -f "$APP_DIR/requirements.txt" ]; then
    chown root:root "$APP_DIR/requirements.txt"
  fi
}

install_config_files() {
  echo "Installing config files..."
  install -m 640 ./config/config.env "$CFG_DIR/.env"
  install -m 640 ./config/smb-credentials "$CFG_DIR/smb-credentials"

  chown root:"$SERVICE_GROUP" "$CFG_DIR/.env" "$CFG_DIR/smb-credentials"
  chmod 640 "$CFG_DIR/.env" "$CFG_DIR/smb-credentials"
}

setup_venv() {
  echo "Creating venv..."
  if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV"
  fi

  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$VENV"

  echo "Installing Python deps..."
  sudo -u "$SERVICE_USER" "$VENV/bin/pip" install --upgrade pip

  if [ -f "$APP_DIR/requirements.txt" ]; then
    sudo -u "$SERVICE_USER" "$VENV/bin/pip" install -r "$APP_DIR/requirements.txt"
  else
    sudo -u "$SERVICE_USER" "$VENV/bin/pip" install supabase python-dotenv pyodbc flask requests
  fi
}

install_wrappers() {
  echo "Installing wrapper commands..."

  cat > "$WRAP_CONNECTOR" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VENV_PY="/opt/nl-connector/app/.venv/bin/python"
SCRIPT="/opt/nl-connector/app/connector.py"
SERVICE_USER="nlconnector"

if [ "$(id -u)" -eq 0 ]; then
  exec runuser -u "$SERVICE_USER" -- "$VENV_PY" "$SCRIPT" "$@"
fi

if [ "$(id -un)" = "$SERVICE_USER" ]; then
  exec "$VENV_PY" "$SCRIPT" "$@"
fi

echo "ERROR: Run as root or $SERVICE_USER. Example: sudo nl-connector-run" >&2
exit 1
EOF

  cat > "$WRAP_SELECTOR" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VENV_PY="/opt/nl-connector/app/.venv/bin/python"
SCRIPT="/opt/nl-connector/app/selector.py"
SERVICE_USER="nlconnector"

if [ "$(id -u)" -eq 0 ]; then
  exec runuser -u "$SERVICE_USER" -- "$VENV_PY" "$SCRIPT" "$@"
fi

if [ "$(id -un)" = "$SERVICE_USER" ]; then
  exec "$VENV_PY" "$SCRIPT" "$@"
fi

echo "ERROR: Run as root or $SERVICE_USER. Example: sudo nl-selector-run" >&2
exit 1
EOF

  cat > "$WRAP_CONTROL_API" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
VENV_PY="/opt/nl-connector/app/.venv/bin/python"
SCRIPT="/opt/nl-connector/app/control_api.py"
SERVICE_USER="nlconnector"

if [ "$(id -u)" -eq 0 ]; then
  exec runuser -u "$SERVICE_USER" -- "$VENV_PY" "$SCRIPT" "$@"
fi

if [ "$(id -un)" = "$SERVICE_USER" ]; then
  exec "$VENV_PY" "$SCRIPT" "$@"
fi

echo "ERROR: Run as root or $SERVICE_USER. Example: sudo nl-control-api-run" >&2
exit 1
EOF

  cat > "$WRAP_APPLY_SCHEDULE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run as root. Example: sudo nl-connector-apply-schedule" >&2
  exit 1
fi
exec /opt/nl-connector/app/apply_schedule.sh "$@"
EOF

  cat > "$WRAP_UPDATE_SHARE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run as root. Example: sudo nl-connector-update-share --host 192.168.1.10 --share NiceLabelIn" >&2
  exit 1
fi
exec /opt/nl-connector/app/update_share.sh "$@"
EOF

  chmod 755 \
    "$WRAP_CONNECTOR" \
    "$WRAP_SELECTOR" \
    "$WRAP_CONTROL_API" \
    "$WRAP_APPLY_SCHEDULE" \
    "$WRAP_UPDATE_SHARE"

  chown root:root \
    "$WRAP_CONNECTOR" \
    "$WRAP_SELECTOR" \
    "$WRAP_CONTROL_API" \
    "$WRAP_APPLY_SCHEDULE" \
    "$WRAP_UPDATE_SHARE"
}

install_sudoers_rule() {
  echo "Installing sudoers rule for update_share.sh..."
  cat > "$SUDOERS_UPDATE_SHARE" <<EOF
$SERVICE_USER ALL=(root) NOPASSWD: /opt/nl-connector/app/update_share.sh
EOF
  chmod 440 "$SUDOERS_UPDATE_SHARE"
  visudo -cf "$SUDOERS_UPDATE_SHARE" >/dev/null || die "Invalid sudoers rule generated at $SUDOERS_UPDATE_SHARE"
}

setup_mount() {
  echo "Setting up SMB mount..."

  local USER_UID USER_GID
  USER_UID="$(id -u "$SERVICE_USER")"
  USER_GID="$(id -g "$SERVICE_USER")"

  local FSTAB_LINE="//${WINDOWS_HOST}/${SHARE_NAME} ${MOUNT_POINT} cifs credentials=${CFG_DIR}/smb-credentials,uid=${USER_UID},gid=${USER_GID},iocharset=utf8,vers=3.0,file_mode=0664,dir_mode=0775,nounix 0 0"

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
  sudo -u "$SERVICE_USER" touch "${MOUNT_POINT}/_nlconnector_write_test.txt" || die "$SERVICE_USER cannot write to ${MOUNT_POINT}. Check Windows share + NTFS permissions."
}

install_systemd_units() {
  systemctl stop connector-control-api.service 2>/dev/null || true
  systemctl disable connector-control-api.service 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/connector-control-api.service

  echo "Installing systemd unit files..."
  install -m 644 ./systemd/nl-connector.service "$CONNECTOR_SERVICE"
  install -m 644 ./systemd/nl-connector.timer "$CONNECTOR_TIMER"
  install -m 644 ./systemd/selector.service "$SELECTOR_SERVICE"
  install -m 644 ./systemd/selector.timer "$SELECTOR_TIMER"
  install -m 644 ./systemd/cleanup-retention.service "$CLEANUP_SERVICE"
  install -m 644 ./systemd/cleanup-retention.timer "$CLEANUP_TIMER"

  rm -f "$CONTROL_API_SERVICE"

  echo "Normalizing unit files to Unix line endings..."
  sed -i 's/\r$//' \
    "$CONNECTOR_SERVICE" \
    "$CONNECTOR_TIMER" \
    "$SELECTOR_SERVICE" \
    "$SELECTOR_TIMER" \
    "$CLEANUP_SERVICE" \
    "$CLEANUP_TIMER"

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
  sudo -u "$SERVICE_USER" "$VENV/bin/python" -c "import supabase, dotenv, pyodbc, flask; print('deps OK')" || true

  echo "DONE."
  echo "Logs: $LOG_DIR/connector.log"
  echo "Cleanup log: $LOG_DIR/cleanup.log"
  echo "Mount: $MOUNT_POINT"
  echo
  echo "Wrapper commands:"
  echo "  sudo nl-selector-run"
  echo "  sudo nl-connector-run"
  echo "  sudo nl-control-api-run"
  echo "  sudo nl-connector-apply-schedule"
  echo "  sudo nl-connector-update-share --host <windows_host> --share <share_name> [--mount <mount_point>]"
  echo
  echo "Systemd manual test:"
  echo "  sudo systemctl start ${SELECTOR_NAME}.service"
  echo "  sudo systemctl start ${CONNECTOR_NAME}.service"
  echo "  sudo systemctl start ${CLEANUP_NAME}.service"
}

main() {
  need_root
  check_required_files
  validate_config_env
  validate_smb_credentials
  load_mount_config
  preflight_checks
  install_deps
  create_user_if_needed
  create_dirs
  install_app_files
  install_config_files
  setup_venv
  install_wrappers
  install_sudoers_rule
  setup_mount
  install_systemd_units
  echo "Applying schedules from config..."
  "$APP_DIR/apply_schedule.sh"
  final_checks
}

main
