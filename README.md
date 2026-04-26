# Stream CBTV — Runbook

## Quick Deploy (you know what you're doing)

```bash
# 1. Mac — deploy script handles everything
bash "/Users/cbaldwin/Documents/Home/Stream CBTV/deploy.sh" <device-ip>

# 2. Device — as root (prompted by deploy script)
su -
cd /tmp && unzip -o cbtv.zip && cd cbtv && bash setup.sh
```

Reboot when prompted. Done.

---

Full redeploy guide for the OnLogic CL210G / Beelink U55. Follow top to bottom.

---

## Hardware

- OnLogic CL210G (Intel Apollo Lake, 4 GB RAM, 32 GB eMMC) — or —
- Beelink U55 (Intel i3 5th gen, 8 GB RAM, 256 GB M.2 SSD)
- HDMI to TV
- Ethernet to router (wired only, no WiFi)

---

## 1. Flash Debian 13

Download the `amd64` netinstall ISO from debian.org/releases/trixie.

Flash to USB with Balena Etcher or `dd`, then boot from it
(set boot order in BIOS — Del or F2 on POST).

**Installer settings:**
- Graphical install
- Hostname: `cbtv`
- Domain name: leave blank
- Create a user (e.g. `logic`) — only used for initial SSH access
- Software selection: uncheck everything, check only **SSH server**

---

## 2. Get the IP

Plug ethernet in before boot. After install reboots:

```bash
ip a
```

Look for the `inet` address on the ethernet interface (e.g. `enp2s0`).
Set a DHCP reservation on your router for that MAC address so the IP never changes.

---

## 3. Deploy

Run the deploy script from your Mac:

```bash
bash "/Users/cbaldwin/Documents/Home/Stream CBTV/deploy.sh" <device-ip>
```

Then SSH in and run the commands it prints.

---

## 4. Verify

After reboot (~20s) the TV shows the Stream CBTV idle screen with the device IP.

On your phone go to `http://<device-ip>:7777` and bookmark it.

**Smoke test:**
- Paste a URL → GO — video loads on TV
- Stream CBTV logo on phone UI returns TV to idle screen
- Tab / Shift+Tab navigates page elements (red outline shows focus)
- Select activates the focused element
- Reset clears focus back to first element on page
- Reboot / Shutdown both require confirmation
- Audio plays through HDMI

---

## Troubleshooting

**TV shows blank or Chromium crashed:**
```bash
sudo systemctl status cbtv
sudo journalctl -u cbtv -f
```

**Control UI unreachable from phone:**
```bash
sudo systemctl restart cbtv
```

**No audio:**
```bash
aplay -l    # find HDMI card/device numbers
```
Then update `/etc/asound.conf` with the correct card and device numbers and reboot.

**Disk getting full:**
Add `--disk-cache-size=52428800` to the Chromium launch in:
```bash
nano /home/cbtv/.config/openbox/autostart
```
Then reboot.

---

## File Structure

```
cbtv/
├── setup.sh        — one-shot install script (Debian 13, run as root)
├── migrate.sh      — migrate an old streambox install to Stream CBTV
├── server.py       — Flask control server, port 7777, CDP-based
├── templates/
│   ├── index.html  — phone remote UI
│   └── tv.html     — TV idle screen
└── README.md       — this file
```

```
Stream CBTV/
├── deploy.sh       — Mac-side deploy script
├── cbtv.zip        — distributable (built by deploy.sh)
├── cbtv/           — project source (this repo)
└── streambox_spec.docx — original spec
```

---

## SSH Quick Reference

```bash
# Connect
ssh logic@<device-ip>

# Service
sudo systemctl status cbtv
sudo systemctl restart cbtv
sudo journalctl -u cbtv -f

# Disk
df -h

# Chromium launch args
nano /home/cbtv/.config/openbox/autostart
```
