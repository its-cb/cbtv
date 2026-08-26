#!/usr/bin/env python3
"""
Stream CBTV Control Server
Runs on the CL210G, listens on port 7777.
All Chromium control via Chrome DevTools Protocol (CDP).
"""

import subprocess
import os
import re
import json
import time
import threading
import urllib.request
import websocket
from flask import Flask, request, jsonify, render_template, make_response

app = Flask(__name__)

DISPLAY = ":0"
XAUTHORITY = "/home/cbtv/.Xauthority"
env = {**os.environ, "DISPLAY": DISPLAY, "XAUTHORITY": XAUTHORITY}
pulse_env = {**env, "XDG_RUNTIME_DIR": f"/run/user/{os.getuid()}"}


# ── Audio ────────────────────────────────────────────────────
# Three things can independently silence HDMI: the HDA codec's own mute
# switches, the PulseAudio sink, and the stream on that sink. PulseAudio can
# only see the last two, so a muted codec pin looks like a perfectly healthy
# RUNNING sink with no sound coming out. Everything below fixes all three.

GENERIC_HDMI = re.compile(r"^HDMI(\s*\d+)?$", re.I)

# Playback controls worth unmuting, and the input-side ones to leave alone so
# we never open a mic loopback onto the TV. "Front Mic" matches both lists on
# purpose -- the exclusions win.
MIXER_KEYWORDS = ("master", "pcm", "iec958", "hdmi", "digital",
                  "speaker", "headphone", "front", "spdif", "s/pdif")
MIXER_EXCLUDE = ("mic", "capture", "line", "aux", "beep", "loopback", "boost")


def _sh(cmd, pulse=True, timeout=15):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              env=pulse_env if pulse else env)
    except Exception as e:
        return subprocess.CompletedProcess(cmd, 1, "", str(e))


def _eld_monitors(card):
    """Names of TVs the codec sees on this card, read from the ELD."""
    names = []
    try:
        base = f"/proc/asound/card{card}"
        for fn in sorted(os.listdir(base)):
            if not fn.startswith("eld#"):
                continue
            txt = open(os.path.join(base, fn)).read()
            if not re.search(r"monitor_present\s+1", txt):
                continue
            if not re.search(r"eld_valid\s+1", txt):
                continue
            m = re.search(r"monitor_name\s+(.+)", txt)
            if m:
                names.append(m.group(1).strip())
    except Exception:
        pass
    return names


def _hdmi_pcms():
    """HDMI playback devices from `aplay -l`, most-likely-connected first.

    A plugged-in TV writes its name into the ELD and ALSA uses that as the PCM
    label -- `device 3: HDMI 0 [LG TV SSCR2]` has a TV on it, `device 7: HDMI 1
    [HDMI 1]` is a bare pin. Picking on that keeps us off the dead ports
    instead of just grabbing the first HDMI device we find.
    """
    pcms = []
    eld_cache = {}
    for line in _sh(["aplay", "-l"], pulse=False).stdout.splitlines():
        m = re.match(r"card (\d+):.*?device (\d+): (.*?) \[(.*?)\]\s*$", line)
        if not m:
            continue
        card, dev, pcm, label = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
        if "hdmi" not in pcm.lower() and "hdmi" not in label.lower():
            continue
        if card not in eld_cache:
            eld_cache[card] = _eld_monitors(card)
        monitors = eld_cache[card]
        if monitors:
            connected = any(label.strip().lower() == n.lower() for n in monitors)
        else:
            connected = not GENERIC_HDMI.match(label.strip())
        pcms.append({"card": card, "device": dev, "label": label,
                     "connected": connected})
    pcms.sort(key=lambda p: (not p["connected"], p["device"]))
    return pcms


def _alsa_unmute(card):
    """Unmute and max every playback control on the card.

    Debian leaves the HDA IEC958/HDMI switches off on some boards, which is
    invisible from PulseAudio's side -- this is the usual cause of video with
    no audio.
    """
    touched = []
    for line in _sh(["amixer", "-c", str(card), "scontrols"], pulse=False).stdout.splitlines():
        m = re.search(r"'(.+?)',(\d+)", line)
        if not m:
            continue
        name, idx = m.group(1), m.group(2)
        low = name.lower()
        if not any(k in low for k in MIXER_KEYWORDS) or any(k in low for k in MIXER_EXCLUDE):
            continue
        ctl = f"{name},{idx}"
        # Separate calls: controls with no volume reject "100%", controls with
        # no switch reject "unmute", and we want whichever one applies.
        _sh(["amixer", "-c", str(card), "-q", "sset", ctl, "unmute"], pulse=False)
        _sh(["amixer", "-c", str(card), "-q", "sset", ctl, "100%"], pulse=False)
        touched.append(ctl)
    return touched


def _sink_index(name):
    for line in _sh(["pactl", "list", "sinks", "short"]).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1] == name:
            return parts[0]
    return None


def _ensure_sink(card, device):
    """Return the name of a PulseAudio sink pointed at hw:card,device."""
    want = f"hw:{card},{device}"

    # An hdmi_out left over from a previous boot may be on the wrong pin.
    for line in _sh(["pactl", "list", "modules", "short"]).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] == "module-alsa-sink" and "sink_name=hdmi_out" in parts[2]:
            if f"device={want}" in parts[2]:
                return "hdmi_out"
            _sh(["pactl", "unload-module", parts[0]])
            break

    # Prefer a natively detected HDMI sink where PulseAudio manages the card.
    for line in _sh(["pactl", "list", "sinks", "short"]).stdout.splitlines():
        parts = line.split("\t")
        name = parts[1] if len(parts) >= 2 else ""
        if name.startswith("alsa_output.") and "hdmi" in name.lower():
            return name

    _sh(["pactl", "load-module", "module-alsa-sink", f"device={want}",
         "sink_name=hdmi_out", "rate=48000", "format=s16le", "channels=2"])
    return "hdmi_out"


def _apply_sink(sink):
    """Make `sink` the destination and unmute it and everything playing on it.

    Returns False if the sink has gone away, so the caller can re-route.
    """
    idx = _sink_index(sink)
    if idx is None:
        return False
    _sh(["pactl", "set-default-sink", sink])
    _sh(["pactl", "set-sink-mute", sink, "0"])
    _sh(["pactl", "set-sink-volume", sink, "100%"])
    for line in _sh(["pactl", "list", "sink-inputs", "short"]).stdout.splitlines():
        parts = line.split("\t")
        if not parts or not parts[0].strip():
            continue
        stream = parts[0].strip()
        if len(parts) < 2 or parts[1].strip() != idx:
            _sh(["pactl", "move-sink-input", stream, sink])
        _sh(["pactl", "set-sink-input-mute", stream, "0"])
        _sh(["pactl", "set-sink-input-volume", stream, "100%"])
    return True


def _audio_route():
    """Full HDMI audio setup. Returns what it found and what it did."""
    result = {"ok": False}
    pcms = _hdmi_pcms()
    result["candidates"] = pcms
    if not pcms:
        result["error"] = "no HDMI playback device found"
        return result
    pick = pcms[0]
    result["device"] = f"hw:{pick['card']},{pick['device']}"
    result["monitor"] = pick["label"]
    result["connected"] = pick["connected"]
    result["unmuted"] = _alsa_unmute(pick["card"])
    sink = _ensure_sink(pick["card"], pick["device"])
    result["sink"] = sink
    result["ok"] = _apply_sink(sink)
    if not result["ok"]:
        result["error"] = f"sink {sink} did not come up"
    return result


def _audio_setup():
    """Keep HDMI audio wired up for as long as we run.

    PulseAudio, X and Chromium all come up on their own schedule and Chromium
    opens a new stream every time a page starts playing, so this re-applies
    instead of running once at boot and hoping.
    """
    sink = None
    while True:
        try:
            if _sh(["pactl", "info"]).returncode != 0:
                sink = None            # PulseAudio not up yet (or restarted)
            elif sink is None:
                res = _audio_route()
                if res.get("ok"):
                    sink = res["sink"]
                    print(f"audio: {res['device']} [{res['monitor']}] -> {sink}, "
                          f"unmuted {', '.join(res['unmuted']) or 'nothing'}", flush=True)
            elif not _apply_sink(sink):
                sink = None
        except Exception as e:
            print(f"audio setup failed: {e}", flush=True)
        time.sleep(5 if sink is None else 30)


threading.Thread(target=_audio_setup, daemon=True).start()
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


def get_audio_device():
    """Name of the TV we are actually playing to, for the phone UI."""
    try:
        pcms = _hdmi_pcms()
        if not pcms:
            return "no hdmi audio detected"
        pick = pcms[0]
        return pick["label"] if pick["connected"] else f"{pick['label']} (no TV detected)"
    except Exception:
        return "unknown"


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
        # Poll for a Play button and click it as soon as it appears (up to 6s)
        for attempt in range(12):
            time.sleep(0.5)
            ws.send(json.dumps({
                "id": attempt + 2,
                "method": "Runtime.evaluate",
                "params": {
                    "returnByValue": True,
                    "expression": "(function(){ var b=Array.from(document.querySelectorAll('button')).find(e=>e.textContent.trim()==='Play'); if(b){b.click();return true;} return false; })()"
                }
            }))
            result = json.loads(ws.recv())
            if result.get("result", {}).get("result", {}).get("value") is True:
                break
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

def nocache(html):
    r = make_response(html)
    r.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    r.headers["Pragma"] = "no-cache"
    r.headers["Expires"] = "0"
    return r

@app.route("/")
def index():
    return nocache(render_template("index.html"))


@app.route("/tv")
def tv():
    return nocache(render_template("tv.html"))


@app.route("/api/ip")
def get_ip():
    return jsonify({"ip": get_local_ip(), "audio": get_audio_device()})


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



@app.route("/api/audio/info")
def audio_info():
    """Everything needed to tell whether the TV, PulseAudio or the codec is
    the one swallowing the audio."""
    try:
        pcms = _hdmi_pcms()
        cards = sorted({p["card"] for p in pcms})
        mixer = {str(c): _sh(["amixer", "-c", str(c), "scontents"], pulse=False).stdout.strip()
                 for c in cards}
        eld = {str(c): _eld_monitors(c) for c in cards}
        sinks = _sh(["pactl", "list", "sinks", "short"])
        return jsonify({
            "default_sink": _sh(["pactl", "get-default-sink"]).stdout.strip(),
            "all_sinks": sinks.stdout.strip(),
            "sink_inputs": _sh(["pactl", "list", "sink-inputs", "short"]).stdout.strip(),
            "alsa_devices": _sh(["aplay", "-l"], pulse=False).stdout.strip(),
            "hdmi_candidates": pcms,
            "eld_monitors": eld,
            "mixer": mixer,
            "sinks_detail": _sh(["pactl", "list", "sinks"]).stdout.strip(),
            "sink_inputs_detail": _sh(["pactl", "list", "sink-inputs"]).stdout.strip(),
            "pulse_error": sinks.stderr.strip(),
        })
    except Exception as e:
        return jsonify({"error": str(e)})


@app.route("/api/audio/fix", methods=["POST", "GET"])
def audio_fix():
    """Re-run HDMI detection, unmute the codec, and re-point every stream."""
    try:
        return jsonify(_audio_route())
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})


TONE_WAV = "/tmp/cbtv-tone.wav"


def _tone_file():
    if not os.path.exists(TONE_WAV):
        import wave, math, array
        rate, secs, freq = 48000, 2, 440.0
        mono = [int(11000 * math.sin(2 * math.pi * freq * i / rate))
                for i in range(int(rate * secs))]
        frames = array.array("h", [s for sample in mono for s in (sample, sample)])
        with wave.open(TONE_WAV, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes(frames.tobytes())
    return TONE_WAV


@app.route("/api/audio/test", methods=["POST", "GET"])
def audio_test():
    """Play a 440 Hz tone so audio can be checked without loading a video.

    ?direct=1 bypasses PulseAudio and writes straight to the HDMI device,
    which separates "PulseAudio is misrouting" from "the codec or TV is mute".
    """
    try:
        wav = _tone_file()
        direct = request.args.get("direct") or (request.get_json(silent=True) or {}).get("direct")
        if not direct:
            r = _sh(["paplay", wav], timeout=20)
            return jsonify({"ok": r.returncode == 0, "via": "pulseaudio",
                            "sink": _sh(["pactl", "get-default-sink"]).stdout.strip(),
                            "error": r.stderr.strip()})

        pcms = _hdmi_pcms()
        if not pcms:
            return jsonify({"ok": False, "error": "no HDMI playback device found"})
        pick = pcms[0]
        dev = f"plughw:{pick['card']},{pick['device']}"
        # PulseAudio holds the device open, so hand it over for the duration.
        sink = _sh(["pactl", "get-default-sink"]).stdout.strip()
        if sink:
            _sh(["pactl", "suspend-sink", sink, "1"])
        try:
            r = _sh(["aplay", "-D", dev, wav], pulse=False, timeout=20)
        finally:
            if sink:
                _sh(["pactl", "suspend-sink", sink, "0"])
        return jsonify({"ok": r.returncode == 0, "via": dev,
                        "monitor": pick["label"], "error": r.stderr.strip()})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})



GITHUB_API = "https://api.github.com/repos/its-cb/cbtv/contents"
UPDATE_FILES = [
    ("server.py",            "/opt/cbtv/server.py"),
    ("templates/index.html", "/opt/cbtv/templates/index.html"),
    ("templates/tv.html",    "/opt/cbtv/templates/tv.html"),
]


@app.route("/api/update", methods=["POST"])
def update():
    try:
        changed = False
        for rel, dest in UPDATE_FILES:
            req = urllib.request.Request(
                f"{GITHUB_API}/{rel}",
                headers={"Accept": "application/vnd.github.raw+json",
                         "User-Agent": "stream-cbtv-updater"}
            )
            with urllib.request.urlopen(req, timeout=15) as r:
                new = r.read()
            try:
                old = open(dest, "rb").read()
            except FileNotFoundError:
                old = None
            if new != old:
                open(dest, "wb").write(new)
                changed = True
        if not changed:
            return jsonify({"ok": True, "status": "up_to_date"})
        subprocess.Popen(["sudo", "reboot"])
        return jsonify({"ok": True, "status": "updated"})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)})


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
