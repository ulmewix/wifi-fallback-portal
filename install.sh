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

log() {
  echo "${LOG_PREFIX} $*"
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
    read -r -p "$prompt: " var
    if [[ ${#var} -ge 8 ]]; then
      echo "$var"
      return
    fi
    echo "Password must be at least 8 characters."
  done
}

rand_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 32 /dev/urandom | xxd -p
  fi
}

ensure_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager python3-venv python3-pip git
}

show_ap_diagnostics() {
  local iface="$1"
  echo
  echo "---- NetworkManager diagnostics (AP) ----"
  nmcli -f all con show "$AP_CON_NAME" || true
  nmcli -f general,wifi-properties dev show "$iface" || true
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
  if nmcli con show "$HOME_CON_NAME" >/dev/null 2>&1; then
    nmcli con modify "$HOME_CON_NAME" connection.interface-name "$iface" 802-11-wireless.ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"
  else
    nmcli con add type wifi ifname "$iface" con-name "$HOME_CON_NAME" ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"
  fi
  nmcli con modify "$HOME_CON_NAME" connection.autoconnect yes ipv4.method auto ipv6.method auto
}

create_ap_profile() {
  local iface="$1" ap_ssid="$2" ap_pw="$3"

  if [[ ${#ap_pw} -lt 8 ]]; then
    fail_ap_setup "AP password must be at least 8 characters." "$iface"
  fi

  nmcli con delete "$AP_CON_NAME" >/dev/null 2>&1 || true

  log "Creating AP profile '${AP_CON_NAME}' on ${iface}"
  if ! nmcli con add type wifi ifname "$iface" con-name "$AP_CON_NAME" autoconnect no ssid "$ap_ssid" 802-11-wireless.mode ap ipv4.method shared ipv6.method ignore; then
    fail_ap_setup "Unable to add AP connection." "$iface"
  fi

  if ! nmcli con modify "$AP_CON_NAME" wifi-sec.key-mgmt wpa-psk; then
    fail_ap_setup "Unable to set AP key management." "$iface"
  fi

  if ! nmcli con modify "$AP_CON_NAME" wifi-sec.psk "$ap_pw"; then
    fail_ap_setup "Unable to set AP PSK." "$iface"
  fi

  # Optional channel/band tuning; ignore if unsupported
  if ! nmcli con modify "$AP_CON_NAME" 802-11-wireless.band bg 802-11-wireless.channel 6 >/dev/null 2>&1; then
    log "Band/channel tuning not applied (interface may not support it); continuing."
  fi

  local mode ipv4 keymgmt
  mode=$(nmcli -g 802-11-wireless.mode con show "$AP_CON_NAME" 2>/dev/null || true)
  ipv4=$(nmcli -g ipv4.method con show "$AP_CON_NAME" 2>/dev/null || true)
  keymgmt=$(nmcli -g wifi-sec.key-mgmt con show "$AP_CON_NAME" 2>/dev/null || true)
  if [[ "$mode" != "ap" || "$ipv4" != "shared" || "$keymgmt" != "wpa-psk" ]]; then
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
  git clone "$repo_url" "$tempdir/$PROJECT_NAME"
  echo "$tempdir/$PROJECT_NAME"
}

write_config() {
  local user="$1" home_ssid="$2" home_pw="$3" ap_ssid="$4" ap_pw="$5" web_port="$6" api_key="$7" iface="$8"
  install -d "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<EOF
HOME_SSID=${home_ssid}
HOME_PASSWORD=${home_pw}
AP_SSID=${ap_ssid}
AP_PASSWORD=${ap_pw}
WEB_PORT=${web_port}
WEB_API_KEY=${api_key}
WIFI_IFACE=${iface}
SERVICE_USER=${user}
HOME_CON_NAME=${HOME_CON_NAME}
AP_CON_NAME=${AP_CON_NAME}
EOF
  chmod 600 "$CONFIG_FILE"
}

install_files() {
  local src="$1" user="$2"
  rm -rf "$INSTALL_PREFIX"
  install -d "$INSTALL_PREFIX"
  cp -a "$src/web" "$INSTALL_PREFIX/"
  cp -a "$src/scripts" "$INSTALL_PREFIX/"
  cp -a "$src/config" "$INSTALL_PREFIX/"
  cp -a "$src/systemd" "$INSTALL_PREFIX/"
  cp -a "$src/sudoers" "$INSTALL_PREFIX/"

  install -m 755 "$src/scripts/wifi-fallback.sh" "$BIN_PATH"

  python3 -m venv "$INSTALL_PREFIX/venv"
  "$INSTALL_PREFIX/venv/bin/pip" install --upgrade pip
  "$INSTALL_PREFIX/venv/bin/pip" install -r "$INSTALL_PREFIX/web/requirements.txt"

  sed "s/{{SERVICE_USER}}/${user}/g" "$src/sudoers/wifi-fallback-net" > "$SUDOERS_DIR/wifi-fallback-net"
  sed "s/{{SERVICE_USER}}/${user}/g" "$src/sudoers/wifi-fallback-poweroff" > "$SUDOERS_DIR/wifi-fallback-poweroff"
  chmod 440 "$SUDOERS_DIR/wifi-fallback-net" "$SUDOERS_DIR/wifi-fallback-poweroff"

  sed "s/{{SERVICE_USER}}/${user}/g" "$src/systemd/wifi-fallback-web.service" > "$SYSTEMD_DIR/wifi-fallback-web.service"
  cp "$src/systemd/wifi-fallback-boot.service" "$SYSTEMD_DIR/wifi-fallback-boot.service"
  chmod 644 "$SYSTEMD_DIR/wifi-fallback-web.service" "$SYSTEMD_DIR/wifi-fallback-boot.service"
}

configure_nm() {
  local iface="$1" home_ssid="$2" home_pw="$3" ap_ssid="$4" ap_pw="$5"

  nmcli radio wifi on || true

  create_home_profile "$iface" "$home_ssid" "$home_pw"
  create_ap_profile "$iface" "$ap_ssid" "$ap_pw"
}

enable_services() {
  systemctl daemon-reload
  systemctl enable --now wifi-fallback-web.service
  systemctl enable wifi-fallback-boot.service
}

main() {
  require_root "$@"
  ensure_dependencies

  local default_user default_iface
  default_user=$(detect_default_user)
  default_iface="wlan0"

  echo "=== wifi-fallback-portal installer ==="
  local service_user home_ssid home_pw ap_ssid ap_pw web_port api_key iface
  service_user=$(prompt_default "Service user" "${default_user:-pi}")
  home_ssid=$(prompt_default "HOME_SSID" "HOME_SSID")
  home_pw=$(prompt_default "HOME_PASSWORD" "HOME_PASSWORD")
  ap_ssid=$(prompt_default "AP_SSID" "AP_SSID")
  ap_pw=$(prompt_password "AP_PASSWORD (min 8 chars)")
  web_port=$(prompt_default "WEB_PORT" "4999")
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

