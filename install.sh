#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/ulmewix/wifi-fallback-portal.git"
PROJECT_NAME="wifi-fallback-portal"
INSTALL_PREFIX="/opt/wifi-fallback-portal"
CONFIG_DIR="/etc/wifi-fallback-portal"
CONFIG_FILE="${CONFIG_DIR}/portal.env"
SYSTEMD_DIR="/etc/systemd/system"
SUDOERS_DIR="/etc/sudoers.d"
BIN_PATH="/usr/local/bin/wifi-fallback"
HOME_CON_NAME="HOME_WIFI"
AP_CON_NAME="PORTAL_AP"
LOG_PREFIX="[install]"
DRY_RUN=0

log() {
  echo "${LOG_PREFIX} $*"
}

usage() {
  cat <<EOF
Usage: $0 [--dry-run|-n] [--help]

Options:
  -n, --dry-run   Print actions without making changes
  --help          Show this help and exit
EOF
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[DRY-RUN] Warning: missing command: $cmd"
      return 0
    fi
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
}

write_sudoers_file() {
  local path="$1" line="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write sudoers file $path"
    echo "[DRY-RUN] content: $line"
    return 0
  fi
  printf '%s\n' "$line" > "$path"
  chmod 440 "$path"
  chown root:root "$path"
  if ! visudo -cf "$path"; then
    echo "visudo validation failed for $path" >&2
    rm -f "$path"
    exit 1
  fi
}

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo REPO_URL="${REPO_URL:-}" "$0" "$@"
    else
      echo "Please run as root." >&2
      exit 1
    fi
  fi
}

detect_default_user() {
  local candidate
  candidate="${SUDO_USER:-}"
  if [[ -z "$candidate" ]]; then
    candidate=$(logname 2>/dev/null || true)
  fi
  echo "$candidate"
}

prompt_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  if [[ -z "$var" ]]; then
    var="$default"
  fi
  echo "$var"
}

prompt_password() {
  local prompt="$1" var
  while true; do
    read -r -s -p "$prompt: " var
    echo
    if [[ ${#var} -ge 8 ]]; then
      echo "$var"
      return
    fi
    echo "Password must be at least 8 characters."
  done
}

dotenv_escape() {
  local val="$1"
  val=${val//\\/\\\\}
  val=${val//\"/\\\"}
  echo "$val"
}

rand_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 32 /dev/urandom | xxd -p
  fi
}

ensure_dependencies() {
  run_cmd apt-get update
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager python3-venv python3-pip git
}

show_ap_diagnostics() {
  local iface="$1"
  echo
  echo "---- NetworkManager diagnostics (AP) ----"
  nmcli -f all con show "$AP_CON_NAME" || true
  nmcli -f GENERAL,WIFI-PROPERTIES dev show "$iface" || true
  echo "-----------------------------------------"
}

fail_ap_setup() {
  local msg="$1" iface="$2"
  echo "AP profile setup failed: $msg" >&2
  show_ap_diagnostics "$iface"
  exit 1
}

create_home_profile() {
  local iface="$1" home_ssid="$2" home_pw="$3"
  if [[ -z "$home_pw" ]]; then
    if run_cmd nmcli con show "$HOME_CON_NAME" >/dev/null 2>&1; then
      run_cmd nmcli con modify "$HOME_CON_NAME" connection.interface-name "$iface" 802-11-wireless.ssid "$home_ssid"
      run_cmd nmcli con modify "$HOME_CON_NAME" -wifi-sec >/dev/null 2>&1 || true
      run_cmd nmcli con modify "$HOME_CON_NAME" -802-11-wireless-security >/dev/null 2>&1 || true
    else
      run_cmd nmcli con add type wifi ifname "$iface" con-name "$HOME_CON_NAME" ssid "$home_ssid"
    fi
  else
    if run_cmd nmcli con show "$HOME_CON_NAME" >/dev/null 2>&1; then
      run_cmd nmcli con modify "$HOME_CON_NAME" connection.interface-name "$iface" 802-11-wireless.ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"
    else
      run_cmd nmcli con add type wifi ifname "$iface" con-name "$HOME_CON_NAME" ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"
    fi
  fi
  run_cmd nmcli con modify "$HOME_CON_NAME" connection.autoconnect yes connection.autoconnect-priority 50 ipv4.method auto ipv6.method auto
}

create_ap_profile() {
  local iface="$1" ap_ssid="$2" ap_pw="$3"

  if [[ ${#ap_pw} -lt 8 ]]; then
    fail_ap_setup "AP password must be at least 8 characters." "$iface"
  fi

  run_cmd nmcli con delete "$AP_CON_NAME" >/dev/null 2>&1 || true

  log "Creating AP profile '${AP_CON_NAME}' on ${iface}"
  if ! run_cmd nmcli con add type wifi ifname "$iface" con-name "$AP_CON_NAME" autoconnect no ssid "$ap_ssid" 802-11-wireless.mode ap ipv4.method shared ipv6.method ignore; then
    fail_ap_setup "Unable to add AP connection." "$iface"
  fi

  if ! run_cmd nmcli con modify "$AP_CON_NAME" 802-11-wireless-security.key-mgmt wpa-psk; then
    fail_ap_setup "Unable to set AP key management." "$iface"
  fi

  if ! run_cmd nmcli con modify "$AP_CON_NAME" 802-11-wireless-security.psk "$ap_pw"; then
    fail_ap_setup "Unable to set AP PSK." "$iface"
  fi

  # Optional channel/band tuning; ignore if unsupported
  if ! run_cmd nmcli con modify "$AP_CON_NAME" 802-11-wireless.band bg 802-11-wireless.channel 6 >/dev/null 2>&1; then
    log "Band/channel tuning not applied (interface may not support it); continuing."
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: skipping AP verification."
    return 0
  fi

  local mode ipv4 keymgmt
  mode=$(nmcli -g 802-11-wireless.mode con show "$AP_CON_NAME" 2>/dev/null || true)
  ipv4=$(nmcli -g ipv4.method con show "$AP_CON_NAME" 2>/dev/null || true)
  keymgmt=$(nmcli -g 802-11-wireless-security.key-mgmt con show "$AP_CON_NAME" 2>/dev/null || true)
  if [[ "$mode" != "ap" || "$ipv4" != "shared" || -z "$keymgmt" || "$keymgmt" != "wpa-psk" ]]; then
    fail_ap_setup "Verification failed (mode=${mode}, ipv4=${ipv4}, keymgmt=${keymgmt})." "$iface"
  fi
}

prepare_source() {
  local script_dir tempdir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$script_dir/web/app.py" ]]; then
    echo "$script_dir"
    return
  fi

  tempdir=$(mktemp -d)
  trap 'rm -rf "$tempdir"' EXIT
  local repo_url="${REPO_URL:-$REPO_URL_DEFAULT}"
  echo "Cloning repository from ${repo_url}..."
  run_cmd git clone "$repo_url" "$tempdir/$PROJECT_NAME"
  echo "$tempdir/$PROJECT_NAME"
}

write_config() {
  local user="$1" home_ssid="$2" home_pw="$3" ap_ssid="$4" ap_pw="$5" web_port="$6" api_key="$7" iface="$8"
  local home_ssid_q home_pw_q ap_ssid_q ap_pw_q web_port_q api_key_q iface_q user_q home_con_q ap_con_q
  home_ssid_q=$(dotenv_escape "$home_ssid")
  home_pw_q=$(dotenv_escape "$home_pw")
  ap_ssid_q=$(dotenv_escape "$ap_ssid")
  ap_pw_q=$(dotenv_escape "$ap_pw")
  web_port_q=$(dotenv_escape "$web_port")
  api_key_q=$(dotenv_escape "$api_key")
  iface_q=$(dotenv_escape "$iface")
  user_q=$(dotenv_escape "$user")
  home_con_q=$(dotenv_escape "$HOME_CON_NAME")
  ap_con_q=$(dotenv_escape "$AP_CON_NAME")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write config $CONFIG_FILE"
    echo "[DRY-RUN] HOME_SSID=\"${home_ssid_q}\""
    echo "[DRY-RUN] HOME_PASSWORD=\"<redacted>\""
    echo "[DRY-RUN] AP_SSID=\"${ap_ssid_q}\""
    echo "[DRY-RUN] AP_PASSWORD=\"<redacted>\""
    echo "[DRY-RUN] WEB_PORT=\"${web_port_q}\""
    echo "[DRY-RUN] WEB_API_KEY=\"${api_key_q}\""
    echo "[DRY-RUN] WIFI_IFACE=\"${iface_q}\""
    echo "[DRY-RUN] SERVICE_USER=\"${user_q}\""
    echo "[DRY-RUN] HOME_CON_NAME=\"${home_con_q}\""
    echo "[DRY-RUN] AP_CON_NAME=\"${ap_con_q}\""
    return 0
  fi
  install -d "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
HOME_SSID="${home_ssid_q}"
HOME_PASSWORD="${home_pw_q}"
AP_SSID="${ap_ssid_q}"
AP_PASSWORD="${ap_pw_q}"
WEB_PORT="${web_port_q}"
WEB_API_KEY="${api_key_q}"
WIFI_IFACE="${iface_q}"
SERVICE_USER="${user_q}"
HOME_CON_NAME="${home_con_q}"
AP_CON_NAME="${ap_con_q}"
EOF
  chmod 600 "$CONFIG_FILE"
}

safe_install_prefix() {
  if [[ -z "$INSTALL_PREFIX" ]]; then
    echo "INSTALL_PREFIX is empty; refusing to continue." >&2
    exit 1
  fi
  if [[ "$INSTALL_PREFIX" != "/opt/wifi-fallback-portal" ]]; then
    echo "INSTALL_PREFIX unexpected value: $INSTALL_PREFIX" >&2
    exit 1
  fi
  case "$INSTALL_PREFIX" in
    "/"|"/opt"|"/etc")
      echo "INSTALL_PREFIX is too broad: $INSTALL_PREFIX" >&2
      exit 1
      ;;
  esac
  if [[ ${#INSTALL_PREFIX} -lt 10 ]]; then
    echo "INSTALL_PREFIX looks too short: $INSTALL_PREFIX" >&2
    exit 1
  fi
}

install_files() {
  local src="$1" user="$2"
  safe_install_prefix
  run_cmd rm -rf "$INSTALL_PREFIX"
  run_cmd install -d "$INSTALL_PREFIX"
  run_cmd cp -a "$src/web" "$INSTALL_PREFIX/"
  run_cmd cp -a "$src/scripts" "$INSTALL_PREFIX/"
  run_cmd cp -a "$src/config" "$INSTALL_PREFIX/"
  run_cmd cp -a "$src/systemd" "$INSTALL_PREFIX/"

  run_cmd install -m 755 "$src/scripts/wifi-fallback.sh" "$BIN_PATH"

  run_cmd python3 -m venv "$INSTALL_PREFIX/venv"
  run_cmd "$INSTALL_PREFIX/venv/bin/pip" install --upgrade pip
  run_cmd "$INSTALL_PREFIX/venv/bin/pip" install -r "$INSTALL_PREFIX/web/requirements.txt"

  write_sudoers_file "$SUDOERS_DIR/wifi-fallback-net" "${user} ALL=(root) NOPASSWD: /usr/local/bin/wifi-fallback"
  write_sudoers_file "$SUDOERS_DIR/wifi-fallback-poweroff" "${user} ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY-RUN] write $SYSTEMD_DIR/wifi-fallback-web.service (templated)"
  else
    sed "s/{{SERVICE_USER}}/${user}/g" "$src/systemd/wifi-fallback-web.service" > "$SYSTEMD_DIR/wifi-fallback-web.service"
  fi
  run_cmd cp "$src/systemd/wifi-fallback-boot.service" "$SYSTEMD_DIR/wifi-fallback-boot.service"
  run_cmd chmod 644 "$SYSTEMD_DIR/wifi-fallback-web.service" "$SYSTEMD_DIR/wifi-fallback-boot.service"
}

configure_nm() {
  local iface="$1" home_ssid="$2" home_pw="$3" ap_ssid="$4" ap_pw="$5"

  run_cmd nmcli radio wifi on || true

  create_home_profile "$iface" "$home_ssid" "$home_pw"
  create_ap_profile "$iface" "$ap_ssid" "$ap_pw"
}

enable_services() {
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable --now wifi-fallback-web.service
  run_cmd systemctl enable wifi-fallback-boot.service
  run_cmd systemctl status wifi-fallback-web.service --no-pager || true
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$DRY_RUN" -eq 0 ]]; then
    require_root "$@"
  fi
  require_cmd apt-get
  require_cmd systemctl
  require_cmd nmcli
  ensure_dependencies

  local default_user default_iface
  default_user=$(detect_default_user)
  default_iface="wlan0"

  echo "=== wifi-fallback-portal installer ==="
  echo
  echo "=== WiFi Configuration ==="
  echo "HOME_SSID (your main home WiFi SSID)"
  echo "HOME_PASSWORD (password for your home WiFi; allow empty only if explicitly choosing an open network)"
  echo "AP_SSID (SSID for the fallback hotspot)"
  echo "AP_PASSWORD (password for the fallback hotspot; min 8 characters)"
  echo "WEB_PORT (port used by the web portal; must be numeric 1–65535)"
  echo "WEB_API_KEY (API key for poweroff endpoint; leave blank to disable)"
  echo "WIFI_IFACE (wireless interface used by NetworkManager, usually wlan0)"
  echo
  local service_user home_ssid home_pw ap_ssid ap_pw web_port api_key iface
  service_user=$(prompt_default "Service user" "${default_user:-pi}")
  while true; do
    home_ssid=$(prompt_default "HOME_SSID" "HOME_SSID")
    if [[ -n "$home_ssid" ]]; then
      break
    fi
    echo "HOME_SSID must not be empty."
  done
  while true; do
    read -r -s -p "HOME_PASSWORD: " home_pw
    echo
    if [[ -n "$home_pw" ]]; then
      break
    fi
    read -r -p "Is this an open network? (y/N): " open_net
    case "$open_net" in
      y|Y)
        home_pw=""
        break
      ;;
      *)
        echo "HOME_PASSWORD is required for secured networks."
        ;;
    esac
  done
  while true; do
    ap_ssid=$(prompt_default "AP_SSID" "AP_SSID")
    if [[ -n "$ap_ssid" ]]; then
      break
    fi
    echo "AP_SSID must not be empty."
  done
  ap_pw=$(prompt_password "AP_PASSWORD (min 8 chars)")
  while true; do
    web_port=$(prompt_default "WEB_PORT" "4999")
    if [[ "$web_port" =~ ^[0-9]+$ ]] && [[ "$web_port" -ge 1 ]] && [[ "$web_port" -le 65535 ]]; then
      break
    fi
    echo "WEB_PORT must be a number between 1 and 65535."
  done
  iface=$(prompt_default "WIFI_IFACE" "$default_iface")
  api_key=$(prompt_default "WEB_API_KEY (blank to generate)" "")
  if [[ -z "$api_key" ]]; then
    api_key=$(rand_api_key)
    echo "Generated API key: $api_key"
  fi

  local src_dir
  src_dir=$(prepare_source)

  write_config "$service_user" "$home_ssid" "$home_pw" "$ap_ssid" "$ap_pw" "$web_port" "$api_key" "$iface"
  install_files "$src_dir" "$service_user"
  configure_nm "$iface" "$home_ssid" "$home_pw" "$ap_ssid" "$ap_pw"
  enable_services

  cat <<EOF

Install complete.
- AP SSID: ${ap_ssid}
- Portal URL (AP mode): http://10.42.0.1:${web_port}
- Poweroff API key header: X-Api-Key: ${api_key}

Check logs:
- journalctl -u wifi-fallback-web.service -f
- journalctl -u wifi-fallback-boot.service -b
EOF
}

main "$@"
