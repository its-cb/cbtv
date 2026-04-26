#!/usr/bin/env python3
"""
Stream CBTV Control Server
Runs on the CL210G, listens on port 7777.
All Chromium control via Chrome DevTools Protocol (CDP).
"""

import subprocess
import os
import json
import time
import urllib.request
import websocket
from flask import Flask, request, jsonify, render_template

app = Flask(__name__)

DISPLAY = ":0"
XAUTHORITY = "/home/cbtv/.Xauthority"
env = {**os.environ, "DISPLAY": DISPLAY, "XAUTHORITY": XAUTHORITY}
CDP = "http://localhost:9222"


def get_local_ip():
    try:
        result = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3)
        ips = result.stdout.strip().split()
        for ip in ips:
            if "." in ip and not ip.startswith("169.254"):
                return ip
        return ips[0] if ips else "device-ip"
    except Exception:
        return "device-ip"


def cdp_tab():
    with urllib.request.urlopen(f"{CDP}/json", timeout=3) as r:
        tabs = json.loads(r.read())
    return next((t for t in tabs if t.get("type") == "page"), None)


def cdp_navigate(url):
    try:
        tab = cdp_tab()
        if not tab:
            return False
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=5)
        ws.send(json.dumps({"id": 1, "method": "Page.navigate", "params": {"url": url}}))
        ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"CDP navigate: {e}")
        return False


def cdp_cmd(method, params=None):
    try:
        tab = cdp_tab()
        if not tab:
            return False
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=5)
        msg = {"id": 1, "method": method}
        if params:
            msg["params"] = params
        ws.send(json.dumps(msg))
        ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"CDP {method}: {e}")
        return False


def cdp_keys(key, code, count=1, modifiers=0):
    """Send key down+up to the active page, optionally multiple times."""
    try:
        tab = cdp_tab()
        if not tab:
            return False
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=5)
        for i in range(count):
            for evt in ("keyDown", "keyUp"):
                ws.send(json.dumps({
                    "id": i * 2 + 1,
                    "method": "Input.dispatchKeyEvent",
                    "params": {"type": evt, "key": key, "code": code, "modifiers": modifiers}
                }))
                ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"CDP key: {e}")
        return False


def cdp_eval(js):
    """Execute JavaScript in the active page context."""
    try:
        tab = cdp_tab()
        if not tab:
            return False
        ws = websocket.create_connection(tab["webSocketDebuggerUrl"], timeout=5)
        ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": js}}))
        ws.recv()
        ws.close()
        return True
    except Exception as e:
        print(f"CDP eval: {e}")
        return False


KEY_MAP = {
    "space":    (" ",        "Space"),
    "Left":     ("ArrowLeft",  "ArrowLeft"),
    "Right":    ("ArrowRight", "ArrowRight"),
    "Up":       ("ArrowUp",    "ArrowUp"),
    "Down":     ("ArrowDown",  "ArrowDown"),
    "f":        ("f",          "KeyF"),
    "m":        ("m",          "KeyM"),
    "k":        ("k",          "KeyK"),
    "Escape":   ("Escape",     "Escape"),
    "F11":      ("F11",        "F11"),
    "Tab":      ("Tab",        "Tab"),
    "Enter":    ("Enter",      "Enter"),
    "PageUp":   ("PageUp",     "PageUp"),
    "PageDown": ("PageDown",   "PageDown"),
}


# ── Routes ────────────────────────────────────────────────���───

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/tv")
def tv():
    return render_template("tv.html")


@app.route("/api/ip")
def get_ip():
    return jsonify({"ip": get_local_ip()})


@app.route("/api/load", methods=["POST"])
def load_url():
    data = request.get_json()
    url = data.get("url", "").strip()
    if not url:
        return jsonify({"ok": False, "error": "No URL provided"}), 400
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    return jsonify({"ok": cdp_navigate(url), "url": url})


@app.route("/api/key", methods=["POST"])
def send_key():
    data = request.get_json()
    key = data.get("key", "")
    if not key:
        return jsonify({"ok": False, "error": "No key provided"}), 400
    if key == "ShiftTab":
        return jsonify({"ok": cdp_keys("Tab", "Tab", modifiers=8), "key": key})
    k, c = KEY_MAP.get(key, (key, key))
    return jsonify({"ok": cdp_keys(k, c), "key": key})


FOCUS_CSS = """
(function() {
  if (!document.getElementById('sb-focus')) {
    var s = document.createElement('style');
    s.id = 'sb-focus';
    s.textContent = '*:focus { outline: 4px solid #ff3333 !important; outline-offset: 3px !important; box-shadow: 0 0 20px rgba(255,51,51,0.6) !important; }';
    document.head.appendChild(s);
  }
  var el = document.activeElement;
  if (el && el !== document.body) el.scrollIntoView({block: 'center', behavior: 'smooth'});
})();
"""


@app.route("/api/nav/reset", methods=["POST"])
def nav_reset():
    """Yank focus out of any iframe by explicitly focusing the first visible
    interactive element in the main frame, then inject the highlight CSS."""
    js = """
(function() {
  var old = document.getElementById('sb-focus');
  if (old) old.remove();
  var s = document.createElement('style');
  s.id = 'sb-focus';
  s.textContent = '*:focus { outline: 4px solid #ff3333 !important; outline-offset: 3px !important; box-shadow: 0 0 20px rgba(255,51,51,0.6) !important; }';
  document.head.appendChild(s);
  window.scrollTo(0, 0);
  var el = Array.from(document.querySelectorAll(
    'a[href], button, [role="button"], [tabindex]:not([tabindex="-1"]), input, select'
  )).find(function(e) {
    var r = e.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && !e.disabled;
  });
  if (el) { el.focus(); el.scrollIntoView({block: 'center'}); }
})();
"""
    cdp_eval(js)
    return jsonify({"ok": True})


@app.route("/api/nav/tab", methods=["POST"])
def nav_tab():
    """Tab (or Shift+Tab), then scroll focused element into view."""
    data = request.get_json() or {}
    shift = data.get("shift", False)
    cdp_keys("Tab", "Tab", modifiers=8 if shift else 0)
    time.sleep(0.1)
    cdp_eval(FOCUS_CSS)
    return jsonify({"ok": True})


@app.route("/api/nav/select", methods=["POST"])
def nav_select():
    """Activate the focused element. Sends a trusted CDP Enter keypress (works on
    elements that block synthetic clicks) plus a JS click for everything else."""
    cdp_eval("var el=document.activeElement; if(el && el.click) el.click();")
    return jsonify({"ok": cdp_keys("Enter", "Enter")})


@app.route("/api/fullscreen", methods=["POST"])
def fullscreen():
    return jsonify({"ok": cdp_keys("F11", "F11")})


@app.route("/api/refresh", methods=["POST"])
def refresh():
    return jsonify({"ok": cdp_cmd("Page.reload")})


@app.route("/api/back", methods=["POST"])
def go_back():
    return jsonify({"ok": cdp_cmd("Page.goBack")})


@app.route("/api/home", methods=["POST"])
def go_home():
    return jsonify({"ok": cdp_navigate("http://localhost:7777/tv")})



@app.route("/api/reboot", methods=["POST"])
def reboot():
    subprocess.Popen(["sudo", "reboot"])
    return jsonify({"ok": True})


@app.route("/api/shutdown", methods=["POST"])
def shutdown():
    subprocess.Popen(["sudo", "shutdown", "-h", "now"])
    return jsonify({"ok": True})


if __name__ == "__main__":
    print("Stream CBTV control server starting on port 7777...")
    app.run(host="0.0.0.0", port=7777, debug=False)
