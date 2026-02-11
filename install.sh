#!/usr/bin/env bash
set -euo pipefail

# ====== Settings (customer IT supplies these) ======
# Windows LAN IP (Wi-Fi/Ethernet), NOT VirtualBox host-only IP
WINDOWS_IP="${WINDOWS_IP:-}"
SHARE_NAME="${SHARE_NAME:-NiceLabelIn}"

# Where to mount the Windows watch folder
MOUNT_POINT="/mnt/nicelabel/in"

# Install locations
BASE="/opt/nl-connector"
APP_DIR="$BASE/app"
CFG_DIR="$BASE/config"
LOG_DIR="/var/log/nl-connector"

VENV="$APP_DIR/.venv"

SERVICE_NAME="nl-connector"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

# ====== Helpers ======
die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo ./install.sh"
  fi
}

check_required_files() {
  [ -f "./app/connector.py" ] || die "Missing ./app/connector.py"
  [ -f "./app/cleanup_retention.sh" ] || die "Missing ./app/cleanup_retention.sh"
  [ -f "./config/config.env" ] || die "Missing ./config/config.env (copy from template)"
  [ -f "./config/smb-credentials" ] || die "Missing ./config/smb-credentials (copy from template)"
  [ -f "./systemd/nl-connector.service" ] || die "Missing ./systemd/nl-connector.service"
  [ -f "./systemd/nl-connector.timer" ] || die "Missing ./systemd/nl-connector.timer"
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
  apt-get install -y python3 python3-venv python3-pip cifs-utils
}

create_dirs() {
  echo "Creating directories..."
  mkdir -p "$APP_DIR" "$CFG_DIR" "$BASE/staging" "$BASE/archive" "$BASE/error" "$LOG_DIR" "$(dirname "$MOUNT_POINT")"

  chown -R nlconnector:nlconnector "$APP_DIR" "$BASE/staging" "$BASE/archive" "$BASE/error"
  chown -R nlconnector:nlconnector "$LOG_DIR"
  chmod 755 "$BASE" "$APP_DIR" "$CFG_DIR"
}

install_app_files() {
  echo "Installing app files..."
  install -m 755 ./app/connector.py "$APP_DIR/connector.py"
  install -m 755 ./app/cleanup_retention.sh "$APP_DIR/cleanup_retention.sh"
  chown nlconnector:nlconnector "$APP_DIR/connector.py" "$APP_DIR/cleanup_retention.sh"
}

install_config_files() {
  echo "Installing config files..."
  install -m 640 ./config/config.env "$CFG_DIR/.env"
  install -m 600 ./config/smb-credentials "$CFG_DIR/smb-credentials"
  chown root:root "$CFG_DIR/.env" "$CFG_DIR/smb-credentials"
}

setup_venv() {
  echo "Creating venv..."
  if [ ! -d "$VENV" ]; then
    sudo -u nlconnector python3 -m venv "$VENV"
  fi

  echo "Installing Python deps..."
  sudo -u nlconnector "$VENV/bin/pip" install --upgrade pip
  sudo -u nlconnector "$VENV/bin/pip" install supabase python-dotenv
}

setup_mount() {
  [ -n "$WINDOWS_IP" ] || die "Set WINDOWS_IP first. Example: sudo WINDOWS_IP=192.168.254.103 ./install.sh"

  echo "Setting up SMB mount..."
  mkdir -p "$MOUNT_POINT"

  # UID/GID mapping so nlconnector can write
  local UID GID
  UID="$(id -u nlconnector)"
  GID="$(id -g nlconnector)"

  # Create fstab entry if not present
  local FSTAB_LINE="//${WINDOWS_IP}/${SHARE_NAME}  ${MOUNT_POINT}  cifs  credentials=${CFG_DIR}/smb-credentials,uid=${UID},gid=${GID},iocharset=utf8,vers=3.0,file_mode=0664,dir_mode=0775,nounix  0  0"

  if grep -q "${MOUNT_POINT}  cifs" /etc/fstab; then
    echo "fstab: entry already exists for ${MOUNT_POINT}"
  else
    echo "Adding fstab entry..."
    echo "$FSTAB_LINE" >> /etc/fstab
  fi

  systemctl daemon-reload || true

  # Remount
  umount -f "$MOUNT_POINT" 2>/dev/null || true
  mount -a

  # Write test as nlconnector
  echo "Testing write access to SMB mount..."
  sudo -u nlconnector touch "${MOUNT_POINT}/_nlconnector_write_test.txt" || die "nlconnector cannot write to ${MOUNT_POINT}. Check Windows share + NTFS permissions."
}

install_systemd_units() {
  echo "Installing systemd unit files..."
  install -m 644 ./systemd/nl-connector.service "$SERVICE_FILE"
  install -m 644 ./systemd/nl-connector.timer "$TIMER_FILE"

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.timer"
}

setup_retention_cron() {
  echo "Setting up daily retention cleanup..."
  cat > /etc/cron.daily/nl-connector-retention <<CRON
#!/usr/bin/env bash
/opt/nl-connector/app/cleanup_retention.sh
CRON
  chmod +x /etc/cron.daily/nl-connector-retention
}

final_checks() {
  echo "Final checks..."
  systemctl status "${SERVICE_NAME}.timer" --no-pager || true
  systemctl list-timers --no-pager | grep "${SERVICE_NAME}" || true

  echo "Running connector once manually (as nlconnector)..."
  sudo -u nlconnector "$VENV/bin/python" "$APP_DIR/connector.py" || true

  echo "DONE."
  echo "Logs: $LOG_DIR/connector.log"
  echo "Mount: $MOUNT_POINT"
}

main() {
  need_root
  check_required_files
  install_deps
  create_user_if_needed
  create_dirs
  install_app_files
  install_config_files
  setup_venv
  setup_mount
  install_systemd_units
  setup_retention_cron
  final_checks
}

main
