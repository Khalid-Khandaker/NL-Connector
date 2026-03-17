#!/usr/bin/env bash
set -euo pipefail

CFG="/opt/nl-connector/config/.env"
SMB_CREDS="/opt/nl-connector/config/smb-credentials"
DEFAULT_MOUNT="/mnt/nicelabel/in"
SERVICE_USER="nlconnector"

NEW_HOST=""
NEW_SHARE=""
NEW_MOUNT=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Run as root: sudo /opt/nl-connector/app/update_share.sh --host <windows_host> --share <share_name>"
  fi
}

usage() {
  cat <<EOF
Usage:
  sudo /opt/nl-connector/app/update_share.sh --host <windows_host> --share <share_name> [--mount <mount_point>]

Examples:
  sudo /opt/nl-connector/app/update_share.sh --host 192.168.254.104 --share NiceLabelIn
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

  WINDOWS_HOST="${WINDOWS_HOST:-}"
  SHARE_NAME="${SHARE_NAME:-}"
  MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT}"
}

validate_inputs() {
  NEW_HOST="$(trim "$NEW_HOST")"
  NEW_SHARE="$(trim "$NEW_SHARE")"
  NEW_MOUNT="$(trim "${NEW_MOUNT:-}")"

  [ -n "$NEW_HOST" ] || die "--host is required"
  [ -n "$NEW_SHARE" ] || die "--share is required"

  if [ -z "$NEW_MOUNT" ]; then
    NEW_MOUNT="${MOUNT_POINT:-$DEFAULT_MOUNT}"
  fi

  case "$NEW_SHARE" in
    *" "*)
      die "Share name must not contain spaces unless you are sure your SMB share is created exactly that way."
      ;;
  esac

  case "$NEW_MOUNT" in
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
  echo "  WINDOWS_HOST=$NEW_HOST"
  echo "  SHARE_NAME=$NEW_SHARE"
  echo "  MOUNT_POINT=$NEW_MOUNT"
  echo
  mount | grep "on ${NEW_MOUNT} " || true
}

main() {
  need_root
  parse_args "$@"
  load_cfg
  validate_inputs

  info "Current config:"
  echo "  WINDOWS_HOST=${WINDOWS_HOST:-<empty>}"
  echo "  SHARE_NAME=${SHARE_NAME:-<empty>}"
  echo "  MOUNT_POINT=${MOUNT_POINT:-$DEFAULT_MOUNT}"
  echo

  unmount_if_needed "${MOUNT_POINT:-$DEFAULT_MOUNT}"
  remove_existing_fstab_entries "${MOUNT_POINT:-$DEFAULT_MOUNT}"

  update_env_key "WINDOWS_HOST" "$NEW_HOST"
  update_env_key "SHARE_NAME" "$NEW_SHARE"
  update_env_key "MOUNT_POINT" "$NEW_MOUNT"

  write_fstab_entry "$NEW_HOST" "$NEW_SHARE" "$NEW_MOUNT"
  systemctl daemon-reload || true
  mount_share "$NEW_MOUNT"
  write_test "$NEW_MOUNT"
  show_summary
}

main "$@"
