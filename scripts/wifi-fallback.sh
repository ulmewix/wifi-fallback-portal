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
  local security_line security
  security_line=$(nmcli -t -f SSID,SECURITY dev wifi list | grep -F "${ssid}:" | head -n1 || true)
  if [[ -z "$security_line" ]]; then
    echo "UNKNOWN"
    return
  fi
  security="${security_line#*:}"
  # OPEN vs SECURED decision: explicit OPEN when NetworkManager reports no security.
  if [[ -z "$security" || "$security" == "--" ]]; then
    echo "OPEN"
    return
  fi
  echo "$security"
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

  # OPEN vs SECURED decision: default to secured when detection is unknown.
  if [[ "$security" == "UNKNOWN" ]]; then
    mode="wpa-psk"
  elif [[ "$security" == "OPEN" ]]; then
    mode="open"
  elif echo "$security" | grep -qiE "SAE|WPA3"; then
    mode="sae"
  elif echo "$security" | grep -qiE "WPA"; then
    mode="wpa-psk"
  elif echo "$security" | grep -qi "802\.1X"; then
    log "802.1X/enterprise networks are not supported."
    bring_up_ap
    return 1
  elif echo "$security" | grep -qi "WEP"; then
    log "WEP networks are not supported."
    bring_up_ap
    return 1
  else
    log "Unsupported security: $security"
    bring_up_ap
    return 1
  fi

  if [[ "$mode" != "open" ]]; then
    if [[ -z "$password" ]]; then
      log "Password required for secured network."
      bring_up_ap
      return 1
    fi
    if [[ "$mode" =~ ^(wpa-psk|sae)$ && ${#password} -lt 8 ]]; then
      log "Password too short for secured network."
      bring_up_ap
      return 1
    fi
  fi

  log "Connecting to custom SSID '${ssid}' (mode: $mode) on ${WIFI_IFACE}"
  nmcli con add type wifi ifname "$WIFI_IFACE" con-name "$con_name" ssid "$ssid" >/dev/null

  if [[ "$mode" == "sae" ]]; then
    nmcli con modify "$con_name" wifi-sec.key-mgmt sae wifi-sec.psk "$password"
  elif [[ "$mode" == "wpa-psk" ]]; then
    nmcli con modify "$con_name" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$password"
  else
    nmcli con modify "$con_name" wifi-sec.key-mgmt none
  fi

  nmcli con up "$con_name" >/dev/null 2>&1 || true
  if wait_for_connection "$con_name" "$CONNECT_TIMEOUT"; then
    log "Connected to custom network."
    return 0
  fi

  log "Custom network not reachable; falling back to AP."
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
