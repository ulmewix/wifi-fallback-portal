#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/wifi-fallback-portal/portal.env"
HOME_CON_NAME="${HOME_CON_NAME:-HOME_WIFI}"
AP_CON_NAME="${AP_CON_NAME:-PORTAL_AP}"
WIFI_IFACE_DEFAULT="wlan0"
CONNECT_TIMEOUT=30

log() {
  echo "[wifi-fallback] $*"
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  WIFI_IFACE="${WIFI_IFACE:-$WIFI_IFACE_DEFAULT}"
  HOME_SSID="${HOME_SSID:-}"
}

nm_on() {
  nmcli radio wifi on >/dev/null 2>&1 || true
}

wait_for_connection() {
  local con_name="$1"
  local timeout="${2:-$CONNECT_TIMEOUT}"
  local start elapsed
  start=$(date +%s)
  while true; do
    local active
    active=$(nmcli -t -f NAME,DEVICE con show --active || true)
    if echo "$active" | grep -q "^${con_name}:${WIFI_IFACE}\$"; then
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [[ $elapsed -ge $timeout ]]; then
      return 1
    fi
    sleep 2
  done
}

bring_up_ap() {
  log "Enabling AP '${AP_CON_NAME}' on ${WIFI_IFACE}"
  nm_on
  nmcli con down "$HOME_CON_NAME" >/dev/null 2>&1 || true
  nmcli con up "$AP_CON_NAME" >/dev/null 2>&1 || true
  if wait_for_connection "$AP_CON_NAME" 20; then
    log "AP is active."
    return 0
  fi
  log "Failed to activate AP."
  return 1
}

connect_home() {
  log "Attempting to connect to home Wi-Fi (${HOME_CON_NAME}) on ${WIFI_IFACE}"
  nm_on
  nmcli con down "$AP_CON_NAME" >/dev/null 2>&1 || true
  nmcli con up "$HOME_CON_NAME" >/dev/null 2>&1 || true
  if wait_for_connection "$HOME_CON_NAME" "$CONNECT_TIMEOUT"; then
    log "Connected to home Wi-Fi."
    return 0
  fi
  log "Home Wi-Fi not reachable within timeout; falling back to AP."
  bring_up_ap
  return 1
}

detect_security_mode() {
  local ssid="$1"
  local security_line
  security_line=$(nmcli -t -f SSID,SECURITY dev wifi list | grep -F "${ssid}:" | head -n1 || true)
  echo "${security_line#*:}"
}

connect_custom() {
  local ssid="$1"
  local password="$2"
  local con_name="CUSTOM_WIFI"
  local security mode property

  if [[ -z "$ssid" ]]; then
    log "SSID is required for custom connection."
    return 1
  fi

  nm_on
  nmcli con down "$AP_CON_NAME" >/dev/null 2>&1 || true
  nmcli con delete "$con_name" >/dev/null 2>&1 || true

  security=$(detect_security_mode "$ssid")
  mode=""
  property=""

  if echo "$security" | grep -qiE "SAE|WPA3"; then
    mode="sae"
  elif echo "$security" | grep -qiE "WPA"; then
    mode="wpa-psk"
  elif [[ -z "$security" || "$security" == "--" ]]; then
    mode="open"
  elif echo "$security" | grep -qi "802\.1X"; then
    log "802.1X/enterprise networks are not supported."
    bring_up_ap
    return 1
  else
    log "Unsupported security: $security"
    bring_up_ap
    return 1
  fi

  # Validate password requirements based on network type
  if [[ "$mode" == "open" ]]; then
    if [[ -n "$password" ]]; then
      log "Warning: Password provided for open network '${ssid}'. Ignoring password."
    fi
    log "Connecting to OPEN network '${ssid}' on ${WIFI_IFACE}"
  else
    if [[ ${#password} -lt 8 ]]; then
      log "Secured network detected but password is too short (min 8 chars required for ${mode})."
      bring_up_ap
      return 1
    fi
    log "Connecting to secured network '${ssid}' (${mode}) on ${WIFI_IFACE}"
  fi

  # Create connection profile
  if ! nmcli con add type wifi ifname "$WIFI_IFACE" con-name "$con_name" ssid "$ssid" 2>&1; then
    log "ERROR: Failed to create connection profile for '${ssid}'."
    bring_up_ap
    return 1
  fi

  # Configure security settings
  if [[ "$mode" == "sae" ]]; then
    if ! nmcli con modify "$con_name" wifi-sec.key-mgmt sae wifi-sec.psk "$password" 2>&1; then
      log "ERROR: Failed to configure WPA3-SAE security."
      nmcli con delete "$con_name" >/dev/null 2>&1 || true
      bring_up_ap
      return 1
    fi
  elif [[ "$mode" == "wpa-psk" ]]; then
    if ! nmcli con modify "$con_name" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password" 2>&1; then
      log "ERROR: Failed to configure WPA/WPA2-PSK security."
      nmcli con delete "$con_name" >/dev/null 2>&1 || true
      bring_up_ap
      return 1
    fi
  else
    # Open network - no password
    if ! nmcli con modify "$con_name" wifi-sec.key-mgmt none 2>&1; then
      log "ERROR: Failed to configure open network settings."
      nmcli con delete "$con_name" >/dev/null 2>&1 || true
      bring_up_ap
      return 1
    fi
  fi

  # Attempt connection
  local connect_output
  connect_output=$(nmcli con up "$con_name" 2>&1 || true)
  if wait_for_connection "$con_name" "$CONNECT_TIMEOUT"; then
    log "Successfully connected to '${ssid}'."
    return 0
  fi

  log "Failed to connect to '${ssid}'. Error: ${connect_output}"
  log "Falling back to AP mode."
  nmcli con delete "$con_name" >/dev/null 2>&1 || true
  bring_up_ap
  return 1
}

usage() {
  cat <<EOF
Usage: wifi-fallback <command> [args]
Commands:
  ap                         Bring up the AP profile
  connect-home               Try home Wi-Fi; fallback to AP on failure
  connect-custom <ssid> <password>
                             Connect to custom Wi-Fi (WPA2-PSK/WPA3-SAE); fallback to AP on failure
EOF
}

main() {
  load_config
  local cmd="${1:-}"
  case "$cmd" in
    ap)
      bring_up_ap
      ;;
    connect-home)
      connect_home
      ;;
    connect-custom)
      connect_custom "${2:-}" "${3:-}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

