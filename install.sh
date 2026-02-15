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

write_sudoers_file() {
  local path="$1" line="$2"
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
  if [[ -z "$candidate" ]]; then
    candidate="pi"  # Safe fallback for Raspberry Pi
  fi
  echo "$candidate"
}

validate_user() {
  local user="$1"
  if ! id "$user" >/dev/null 2>&1; then
    echo "Error: User '$user' does not exist on this system." >&2
    return 1
  fi
  return 0
}

prompt_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  if [[ -z "$var" ]]; then
    var="$default"
  fi
  echo "$var"
}

prompt_required() {
  local prompt="$1" var
  while true; do
    read -r -p "$prompt: " var
    var=$(echo "$var" | xargs)  # trim whitespace
    if [[ -n "$var" ]]; then
      echo "$var"
      return
    fi
    echo "This field is required and cannot be empty."
  done
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

prompt_port() {
  local prompt="$1" default="$2" var
  while true; do
    read -r -p "$prompt [$default]: " var
    if [[ -z "$var" ]]; then
      var="$default"
    fi
    if [[ "$var" =~ ^[0-9]+$ ]] && [[ "$var" -ge 1024 ]] && [[ "$var" -le 65535 ]]; then
      echo "$var"
      return
    fi
    echo "Port must be a number between 1024 and 65535."
  done
}

rand_api_key() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif command -v xxd >/dev/null 2>&1; then
    head -c 32 /dev/urandom | xxd -p
  else
    # Fallback: use od which is more universal
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

check_python_version() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found. Please install Python 3.7 or later." >&2
    exit 1
  fi
  
  local version
  version=$(python3 -c 'import sys; print("%d.%d" % (sys.version_info.major, sys.version_info.minor))' 2>/dev/null || echo "0.0")
  local major minor
  major=$(echo "$version" | cut -d. -f1)
  minor=$(echo "$version" | cut -d. -f2)
  
  if [[ "$major" -lt 3 ]] || [[ "$major" -eq 3 && "$minor" -lt 7 ]]; then
    echo "Error: Python 3.7 or later is required (found Python $version)." >&2
    exit 1
  fi
  
  log "Python version $version detected (OK)"
}

ensure_dependencies() {
  log "Updating package lists (this may take a moment)..."
  apt-get update
  log "Installing required packages: network-manager, python3-venv, python3-pip, git"
  DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager python3-venv python3-pip git
  log "Dependencies installed successfully"
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
  
  if nmcli con show "$HOME_CON_NAME" >/dev/null 2>&1; then
    log "Updating existing HOME profile"
    if ! nmcli con modify "$HOME_CON_NAME" connection.interface-name "$iface" 802-11-wireless.ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"; then
      echo "Error: Failed to modify HOME_WIFI profile." >&2
      exit 1
    fi
  else
    log "Creating new HOME profile"
    if ! nmcli con add type wifi ifname "$iface" con-name "$HOME_CON_NAME" ssid "$home_ssid" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$home_pw"; then
      echo "Error: Failed to create HOME_WIFI profile." >&2
      exit 1
    fi
  fi
  
  if ! nmcli con modify "$HOME_CON_NAME" connection.autoconnect yes connection.autoconnect-priority 50 ipv4.method auto ipv6.method auto; then
    echo "Error: Failed to configure HOME_WIFI connection settings." >&2
    exit 1
  fi
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

  if ! nmcli con modify "$AP_CON_NAME" 802-11-wireless-security.key-mgmt wpa-psk; then
    fail_ap_setup "Unable to set AP key management." "$iface"
  fi

  if ! nmcli con modify "$AP_CON_NAME" 802-11-wireless-security.psk "$ap_pw"; then
    fail_ap_setup "Unable to set AP PSK." "$iface"
  fi

  # Optional channel/band tuning; ignore if unsupported
  if ! nmcli con modify "$AP_CON_NAME" 802-11-wireless.band bg 802-11-wireless.channel 6 >/dev/null 2>&1; then
    log "Band/channel tuning not applied (interface may not support it); continuing."
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
  git clone "$repo_url" "$tempdir/$PROJECT_NAME"
  echo "$tempdir/$PROJECT_NAME"
}

write_config() {
  local user="$1" home_ssid="$2" home_pw="$3" ap_ssid="$4" ap_pw="$5" web_port="$6" api_key="$7" iface="$8"
  install -d "$CONFIG_DIR"
  
  # Use printf to safely write config values (prevents variable expansion)
  {
    printf 'HOME_SSID=%s\n' "$home_ssid"
    printf 'HOME_PASSWORD=%s\n' "$home_pw"
    printf 'AP_SSID=%s\n' "$ap_ssid"
    printf 'AP_PASSWORD=%s\n' "$ap_pw"
    printf 'WEB_PORT=%s\n' "$web_port"
    printf 'WEB_API_KEY=%s\n' "$api_key"
    printf 'WIFI_IFACE=%s\n' "$iface"
    printf 'SERVICE_USER=%s\n' "$user"
    printf 'HOME_CON_NAME=%s\n' "$HOME_CON_NAME"
    printf 'AP_CON_NAME=%s\n' "$AP_CON_NAME"
  } > "$CONFIG_FILE"
  
  chmod 600 "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE"
}

install_files() {
  local src="$1" user="$2"
  
  if [[ -d "$INSTALL_PREFIX" ]]; then
    echo ""
    echo "WARNING: Existing installation detected at $INSTALL_PREFIX"
    echo "This will be removed and replaced."
    read -r -p "Continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 0
    fi
  fi
  
  rm -rf "$INSTALL_PREFIX"
  install -d "$INSTALL_PREFIX"
  cp -a "$src/web" "$INSTALL_PREFIX/"
  cp -a "$src/scripts" "$INSTALL_PREFIX/"
  cp -a "$src/config" "$INSTALL_PREFIX/"
  cp -a "$src/systemd" "$INSTALL_PREFIX/"

  install -m 755 "$src/scripts/wifi-fallback.sh" "$BIN_PATH"

  log "Creating Python virtual environment"
  python3 -m venv "$INSTALL_PREFIX/venv"
  log "Installing Python dependencies"
  "$INSTALL_PREFIX/venv/bin/pip" install --upgrade pip
  "$INSTALL_PREFIX/venv/bin/pip" install -r "$INSTALL_PREFIX/web/requirements.txt"

  write_sudoers_file "$SUDOERS_DIR/wifi-fallback-net" "${user} ALL=(root) NOPASSWD: /usr/local/bin/wifi-fallback"
  write_sudoers_file "$SUDOERS_DIR/wifi-fallback-poweroff" "${user} ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff"

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
  systemctl status wifi-fallback-web.service --no-pager || true
}

main() {
  require_root "$@"
  check_python_version
  ensure_dependencies

  local default_user default_iface
  default_user=$(detect_default_user)
  default_iface="wlan0"

  echo "=== wifi-fallback-portal installer ==="
  local service_user home_ssid home_pw ap_ssid ap_pw web_port api_key iface
  
  echo ""
  echo "Service user:"
  echo "The Linux user account that will run the web portal service."
  echo "Example: pi"
  while true; do
    service_user=$(prompt_default "Service user" "${default_user:-pi}")
    if validate_user "$service_user"; then
      break
    fi
    echo "Please enter a valid existing username."
  done
  
  echo ""
  echo "Home WiFi SSID:"
  echo "Enter the name of your main WiFi network (the WiFi you normally use at home)."
  echo "Example: MyHomeWiFi"
  home_ssid=$(prompt_required "HOME_SSID")
  
  echo ""
  echo "Home WiFi password:"
  echo "Enter the password for your main WiFi network (minimum 8 characters)."
  echo "Example: MySecurePassword123"
  home_pw=$(prompt_password "HOME_PASSWORD (min 8 chars)")
  
  echo ""
  echo "Fallback Access Point SSID:"
  echo "The name of the WiFi hotspot that will be created when home WiFi is unavailable."
  echo "Example: RaspberryPi-Portal"
  ap_ssid=$(prompt_required "AP_SSID")
  
  echo ""
  echo "Fallback Access Point password:"
  echo "The password to connect to the fallback hotspot (minimum 8 characters)."
  echo "Example: Portal123"
  ap_pw=$(prompt_password "AP_PASSWORD (min 8 chars)")
  
  echo ""
  echo "Web portal port:"
  echo "The port number where the web control panel will be accessible."
  echo "Example: 4999"
  web_port=$(prompt_port "WEB_PORT" "4999")
  
  echo ""
  echo "WiFi interface:"
  echo "The name of your WiFi network adapter (usually wlan0 on Raspberry Pi)."
  echo "Example: wlan0"
  iface=$(prompt_default "WIFI_IFACE" "$default_iface")
  
  # Verify WiFi interface exists
  if ! nmcli device status | grep -q "^${iface}[[:space:]]"; then
    echo "Error: WiFi interface '$iface' not found." >&2
    echo "Available network interfaces:"
    nmcli device status
    exit 1
  fi
  
  echo ""
  echo "Web API key:"
  echo "Security key for remote poweroff (leave blank to auto-generate a secure key)."
  echo "Example: a1b2c3d4e5f6 or press Enter for auto-generation"
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

