# wifi-fallback-portal

A self-contained Wi-Fi bootstrap and fallback portal for Raspberry Pi OS using NetworkManager and nmcli. On boot it first tries to join a configured "home" Wi-Fi; if not connected within ~30 seconds it automatically starts its own Access Point (AP) with a simple Flask portal on port 4999. From the portal you can:
- Connect to the home Wi-Fi
- Join any custom SSID/password
- Switch back to AP mode
- Safely power off the device (API-key protected)

**Privacy-first:** no real SSIDs or passwords are hardcoded. Use placeholders like `HOME_SSID`, `HOME_PASSWORD`, `AP_SSID`, `AP_PASSWORD`. All secrets live locally in `/etc/wifi-fallback-portal/portal.env`.

## Features
- NetworkManager-based; no direct `wpa_supplicant` edits
- AP mode via `ipv4.method shared` (NAT), typically reachable at `http://10.42.0.1:4999`
- Automatic fallback to AP if home Wi-Fi is unreachable
- Flask + Gunicorn web UI with busy-lock to prevent concurrent actions
- Minimal sudoers privileges: only the network script and `systemctl poweroff`
- Systemd services for boot fallback logic and the web portal

## Requirements
- Raspberry Pi OS (Debian-based)
- NetworkManager (`network-manager`), `python3-venv`, `python3-pip`
- Wi-Fi interface default `wlan0` (override via config)

## Install

### Option A: one-liner (curl, run as root)
```bash
curl -fsSL https://raw.githubusercontent.com/ulmewix/wifi-fallback-portal/main/install.sh | sudo bash
```

### Option B: clone then install
```bash
git clone https://github.com/ulmewix/wifi-fallback-portal.git
cd wifi-fallback-portal
sudo ./install.sh
```

### Installer flow
- Verifies root (re-executes with sudo if needed)
- Installs packages: `network-manager`, `python3-venv`, `python3-pip`
- Prompts for:
  - Service user (default: current non-root user)
  - `HOME_SSID`, `HOME_PASSWORD`
  - `AP_SSID`, `AP_PASSWORD` (min length 8)
  - `WEB_PORT` (default 4999)
  - `WEB_API_KEY` (random if blank; used only as `X-Api-Key` for `/api/poweroff`)
  - Optional `WIFI_IFACE` (default `wlan0`)
- Writes `/etc/wifi-fallback-portal/portal.env` (`chmod 600`)
- Creates NetworkManager profiles:
  - Home: `HOME_WIFI` (autoconnect yes, priority 50). Existing connections for the SSID are left intact; this profile is additive.
  - AP: `PORTAL_AP` (autoconnect no, `ipv4.method shared`, `ipv6.method ignore`)
- Installs `/usr/local/bin/wifi-fallback`
- Installs sudoers rules for the chosen user (only the network script + `systemctl poweroff`)
- Deploys Flask app to `/opt/wifi-fallback-portal/web` with venv at `/opt/wifi-fallback-portal/venv`
- Installs systemd services and enables:
  - `wifi-fallback-web.service` (Gunicorn on `0.0.0.0:${WEB_PORT}`)
  - `wifi-fallback-boot.service` (runs on boot: try home, else AP)

### After install
- AP SSID: `AP_SSID` (password `AP_PASSWORD`)
- Portal URL in AP mode: `http://10.42.0.1:4999` (adjust if `WEB_PORT` changed)
- Logs:
  - `journalctl -u wifi-fallback-web.service -f`
  - `journalctl -u wifi-fallback-boot.service -b`
  - `journalctl -u wifi-fallback-web.service -n 200 --no-pager`
  - `nmcli con show --active`
  - `ss -lntp | grep :4999`

## Usage
- Visit the portal page to:
  - Connect to home Wi-Fi
  - Join a custom network (WPA2-PSK / WPA3-SAE; 802.1X enterprise is rejected)
  - Return to AP mode
  - Power off (requires HTTP header `X-Api-Key: <WEB_API_KEY>`; this is **not** a Wi-Fi password)
- SSH may briefly drop during Wi-Fi switching—this is expected.

## Troubleshooting
- Ensure NetworkManager controls the Wi-Fi interface (`nmcli device status`)
- If AP does not start, check for conflicting autoconnect Wi-Fi profiles and disable them
- Verify sudoers files in `/etc/sudoers.d/` remain `0440` and owned by root
- Re-run `wifi-fallback ap` manually to force AP mode
- Use `nmcli -g NAME,ACTIVE con show` to see active connections

## Uninstall
```bash
sudo ./uninstall.sh
```
- Removes `/opt/wifi-fallback-portal`, `/etc/wifi-fallback-portal`
- Removes systemd units, sudoers entries, and `/usr/local/bin/wifi-fallback`
- Optionally deletes created NetworkManager profiles when prompted

## Security Notes
- Least-privilege sudoers: the web user may only run `/usr/local/bin/wifi-fallback` and `systemctl poweroff` without a password.
- Poweroff endpoint requires `WEB_API_KEY` provided as HTTP header `X-Api-Key` (independent from Wi-Fi credentials).
- Config is stored at `/etc/wifi-fallback-portal/portal.env` with `chmod 600`.

## Regression Test Quick Steps
```bash
nmcli con delete HOME_WIFI || true
nmcli con delete PORTAL_AP || true
sudo ./install.sh
sudo nmcli con up PORTAL_AP
# Check IP and portal at http://10.42.0.1:4999 (adjust if WEB_PORT changed)
```

## Project Status
Initial reference implementation for Raspberry Pi Zero 2 W; tested against NetworkManager workflows. Contributions welcome.

