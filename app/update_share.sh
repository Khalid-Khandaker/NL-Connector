#!/usr/bin/env bash
set -euo pipefail

CFG="/opt/nl-connector/config/.env"
SMB_CREDS="/opt/nl-connector/config/smb-credentials"
SERVICE_USER="nlconnector"

NEW_HOST=""
NEW_SHARE=""
NEW_MOUNT=""

FINAL_HOST=""
FINAL_SHARE=""
FINAL_MOUNT=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo /opt/nl-connector/app/update_share.sh [--host <windows_host>] [--share <share_name>] [--mount <mount_point>]"
  fi
}

usage() {
  cat <<EOF
Usage:
  sudo /opt/nl-connector/app/update_share.sh [--host <windows_host>] [--share <share_name>] [--mount <mount_point>]

Behavior:
  - CLI values override config values in $CFG
  - If a value is not passed in CLI, the script uses the value from $CFG
  - If still missing, the script stops with an error

Examples:
  sudo /opt/nl-connector/app/update_share.sh
  sudo /opt/nl-connector/app/update_share.sh --host 192.168.254.104
  sudo /opt/nl-connector/app/update_share.sh --host DESKTOP-PRINT --share NiceLabelHotIn --mount /mnt/nicelabel/in
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)
        shift
        [ $# -gt 0 ] || die "Missing value for --host"
        NEW_HOST="$1"
        ;;
      --share)
        shift
        [ $# -gt 0 ] || die "Missing value for --share"
        NEW_SHARE="$1"
        ;;
      --mount)
        shift
        [ $# -gt 0 ] || die "Missing value for --mount"
        NEW_MOUNT="$1"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

load_cfg() {
  [ -f "$CFG" ] || die "Missing config file: $CFG"

  set -a
  # shellcheck disable=SC1090
  . "$CFG"
  set +a

  WINDOWS_HOST="$(trim "${WINDOWS_HOST:-}")"
  SHARE_NAME="$(trim "${SHARE_NAME:-}")"
  MOUNT_POINT="$(trim "${MOUNT_POINT:-}")"
}

validate_inputs() {
  NEW_HOST="$(trim "$NEW_HOST")"
  NEW_SHARE="$(trim "$NEW_SHARE")"
  NEW_MOUNT="$(trim "$NEW_MOUNT")"

  FINAL_HOST="${NEW_HOST:-$WINDOWS_HOST}"
  FINAL_SHARE="${NEW_SHARE:-$SHARE_NAME}"
  FINAL_MOUNT="${NEW_MOUNT:-$MOUNT_POINT}"

  [ -n "$FINAL_HOST" ] || die "WINDOWS_HOST is required. Pass --host or define WINDOWS_HOST in $CFG"
  [ -n "$FINAL_SHARE" ] || die "SHARE_NAME is required. Pass --share or define SHARE_NAME in $CFG"
  [ -n "$FINAL_MOUNT" ] || die "MOUNT_POINT is required. Pass --mount or define MOUNT_POINT in $CFG"

  case "$FINAL_SHARE" in
    *" "*)
      die "Share name must not contain spaces unless the SMB share was created with spaces intentionally."
      ;;
  esac

  case "$FINAL_MOUNT" in
    /*) ;;
    *)
      die "Mount point must be an absolute path, example: /mnt/nicelabel/in"
      ;;
  esac

  [ -f "$SMB_CREDS" ] || die "Missing SMB credentials file: $SMB_CREDS"
}

update_env_key() {
  local key="$1"
  local value="$2"

  if grep -qE "^${key}=" "$CFG"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CFG"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CFG"
  fi
}

remove_existing_fstab_entries() {
  local mount_point="$1"

  info "Refreshing /etc/fstab entry for ${mount_point} ..."
  cp /etc/fstab "/etc/fstab.bak.nlconnector.$(date +%Y%m%d%H%M%S)"

  grep -vE "^[[:space:]]*//[^[:space:]]+[[:space:]]+${mount_point}[[:space:]]+cifs([[:space:]]|$)" /etc/fstab > /etc/fstab.tmp || true
  mv /etc/fstab.tmp /etc/fstab
}

unmount_if_needed() {
  local mount_point="$1"

  if mountpoint -q "$mount_point" 2>/dev/null; then
    info "Unmounting existing mount at ${mount_point} ..."
    umount -f "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null || die "Could not unmount existing share at ${mount_point}"
  fi
}

write_fstab_entry() {
  local host="$1"
  local share="$2"
  local mount_point="$3"

  local user_uid user_gid
  user_uid="$(id -u "$SERVICE_USER")"
  user_gid="$(id -g "$SERVICE_USER")"

  mkdir -p "$(dirname "$mount_point")"
  mkdir -p "$mount_point"

  local line="//${host}/${share} ${mount_point} cifs credentials=${SMB_CREDS},uid=${user_uid},gid=${user_gid},iocharset=utf8,vers=3.0,file_mode=0664,dir_mode=0775,nounix 0 0"
  printf '%s\n' "$line" >> /etc/fstab
}

mount_share() {
  local mount_point="$1"

  info "Mounting ${mount_point} ..."
  mount "$mount_point" || die "Mount failed for ${mount_point}. Check Windows host, share name, and credentials."

  mountpoint -q "$mount_point" || die "Mount command completed but ${mount_point} is not mounted."
}

write_test() {
  local mount_point="$1"
  local probe="${mount_point}/_nlconnector_write_test.txt"

  info "Testing write access as ${SERVICE_USER} ..."
  sudo -u "$SERVICE_USER" touch "$probe" || die "Write test failed. Check Windows share permissions and NTFS permissions."
}

show_summary() {
  echo
  echo "Share updated successfully."
  echo "  WINDOWS_HOST=$FINAL_HOST"
  echo "  SHARE_NAME=$FINAL_SHARE"
  echo "  MOUNT_POINT=$FINAL_MOUNT"
  echo
  mount | grep "on ${FINAL_MOUNT} " || true
}

main() {
  need_root
  parse_args "$@"
  load_cfg
  validate_inputs

  info "Current config:"
  echo "  WINDOWS_HOST=${WINDOWS_HOST:-<empty>}"
  echo "  SHARE_NAME=${SHARE_NAME:-<empty>}"
  echo "  MOUNT_POINT=${MOUNT_POINT:-<empty>}"
  echo

  unmount_if_needed "${MOUNT_POINT:-$FINAL_MOUNT}"
  remove_existing_fstab_entries "${MOUNT_POINT:-$FINAL_MOUNT}"

  update_env_key "WINDOWS_HOST" "$FINAL_HOST"
  update_env_key "SHARE_NAME" "$FINAL_SHARE"
  update_env_key "MOUNT_POINT" "$FINAL_MOUNT"

  write_fstab_entry "$FINAL_HOST" "$FINAL_SHARE" "$FINAL_MOUNT"
  systemctl daemon-reload || true
  mount_share "$FINAL_MOUNT"
  write_test "$FINAL_MOUNT"
  show_summary
}

main "$@"
