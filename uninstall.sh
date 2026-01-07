#!/usr/bin/env bash
set -euo pipefail

INSTALL_PREFIX="/opt/wifi-fallback-portal"
CONFIG_DIR="/etc/wifi-fallback-portal"
SYSTEMD_DIR="/etc/systemd/system"
SUDOERS_DIR="/etc/sudoers.d"
BIN_PATH="/usr/local/bin/wifi-fallback"
HOME_CON_NAME="HOME_WIFI"
AP_CON_NAME="PORTAL_AP"

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo "$0" "$@"
    else
      echo "Please run as root." >&2
      exit 1
    fi
  fi
}

remove_services() {
  systemctl disable --now wifi-fallback-web.service >/dev/null 2>&1 || true
  systemctl disable wifi-fallback-boot.service >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/wifi-fallback-web.service" "$SYSTEMD_DIR/wifi-fallback-boot.service"
  systemctl daemon-reload
}

remove_sudoers() {
  rm -f "$SUDOERS_DIR/wifi-fallback-net" "$SUDOERS_DIR/wifi-fallback-poweroff"
}

remove_nm_profiles() {
  read -r -p "Remove NetworkManager profiles (${HOME_CON_NAME}, ${AP_CON_NAME})? [y/N]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    nmcli con delete "$HOME_CON_NAME" >/dev/null 2>&1 || true
    nmcli con delete "$AP_CON_NAME" >/dev/null 2>&1 || true
    echo "NetworkManager profiles removed."
  else
    echo "Keeping NetworkManager profiles."
  fi
}

cleanup_files() {
  rm -rf "$INSTALL_PREFIX"
  rm -rf "$CONFIG_DIR"
  rm -f "$BIN_PATH"
}

main() {
  require_root "$@"
  echo "Uninstalling rpi-wifi-fallback-portal..."
  remove_services
  remove_sudoers
  cleanup_files
  remove_nm_profiles
  echo "Uninstall complete."
}

main "$@"

