# wifi-fallback-portal

This program is primarily designed for the Raspberry Pi Zero 2 W. Its purpose is to simplify initial access to the device and prevent losing connectivity once it is deployed.

**Important note:** I am not a professional developer. I have only basic Linux and scripting knowledge. This project was created with a lot of help from AI tools (OpenAI / ChatGPT and Cursor). It’s shared as-is, mainly for personal use and learning.

What it does (quickly)
- On boot, it tries your home Wi-Fi.
- If that fails after a short wait, it starts its own Wi-Fi hotspot (AP).
- There’s a small web page on port IP:PORT to switch networks or power off.
- SSH can disconnect briefly when Wi-Fi changes—this is normal.

Installation (simple)
```bash
git clone https://github.com/ulmewix/wifi-fallback-portal.git
cd wifi-fallback-portal
sudo bash install.sh
```
If `install.sh` already has execute permission, you can also run:
```bash
sudo ./install.sh
```
The installer will ask for your home Wi-Fi, the hotspot name/password, the web portal port and poweroff password.

Uninstall
```bash
sudo ./uninstall.sh
```


