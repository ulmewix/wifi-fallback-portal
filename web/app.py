import os
import subprocess
import threading
import time
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

LOCK = threading.Lock()
ACTION = {"name": None, "start": 0.0}
WIFI_CMD = ["/usr/bin/sudo", "/usr/local/bin/wifi-fallback"]
POWER_CMD = ["/usr/bin/sudo", "/usr/bin/systemctl", "poweroff"]
WEB_API_KEY = os.getenv("WEB_API_KEY", "")


def busy_state():
    if not LOCK.locked():
        return False, 0
    elapsed = int(time.time() - ACTION.get("start", 0.0))
    return True, elapsed


def run_action(name, cmd):
    if not LOCK.acquire(blocking=False):
        busy, elapsed = busy_state()
        return jsonify({"status": "busy", "elapsed": elapsed}), 409

    ACTION["name"] = name
    ACTION["start"] = time.time()
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        payload = {
            "status": "ok" if result.returncode == 0 else "error",
            "returncode": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }
        return jsonify(payload), (200 if result.returncode == 0 else 500)
    except subprocess.TimeoutExpired:
        return jsonify({"status": "error", "error": "timeout"}), 504
    finally:
        ACTION["name"] = None
        ACTION["start"] = 0.0
        LOCK.release()


@app.route("/", methods=["GET"])
def index():
    busy, elapsed = busy_state()
    return render_template("index.html", busy=busy, elapsed=elapsed)


@app.post("/api/connect-home")
def connect_home():
    return run_action("connect-home", WIFI_CMD + ["connect-home"])


@app.post("/api/connect-custom")
def connect_custom():
    data = request.get_json(silent=True) or {}
    ssid = data.get("ssid", "").strip()
    password = data.get("password", "")
    if not ssid:
        return jsonify({"status": "error", "error": "Missing SSID"}), 400
    if len(password) < 8:
        return jsonify({"status": "error", "error": "Password must be at least 8 characters"}), 400
    return run_action("connect-custom", WIFI_CMD + ["connect-custom", ssid, password])


@app.post("/api/ap")
def ap_mode():
    return run_action("ap", WIFI_CMD + ["ap"])


@app.post("/api/poweroff")
def poweroff():
    api_key = request.headers.get("X-Api-Key", "")
    if not WEB_API_KEY or api_key != WEB_API_KEY:
        return jsonify({"status": "forbidden"}), 403
    try:
        subprocess.Popen(POWER_CMD)
    except Exception as exc:  # noqa: BLE001
        return jsonify({"status": "error", "error": str(exc)}), 500
    return jsonify({"status": "ok", "message": "Poweroff requested"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("WEB_PORT", "4999")))

