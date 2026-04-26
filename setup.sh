#!/bin/bash
# ============================================================
#  Stream CBTV SETUP — OnLogic CL210G / Debian 13
#  Run as root after a fresh Debian 13 minimal install
#  Usage: bash setup.sh
# ============================================================

set -e

CBTV_USER="cbtv"
CBTV_DIR="/opt/cbtv"
SERVICE_PORT="7777"
NEEDS_REBOOT=false

echo ""
echo "╔══════════════════════════════════════╗"
echo "║        Stream CBTV SETUP v2.0        ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 0. Fix clock before anything else ───────────────────────
echo "[0/9] Syncing system clock..."
hwclock --hctosys 2>/dev/null || true
# Install chrony first (standalone, no signature dependency on time)
apt-get -o Acquire::Check-Valid-Until=false update -qq
apt-get install -y -qq chrony
systemctl enable chrony
systemctl start chrony
chronyc makestep 2>/dev/null || true
sleep 3

# ── 1. System update ─────────────────────────────────────────
echo "[1/9] Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# ── 2. Install dependencies ──────────────────────────────────
echo "[2/9] Installing dependencies..."
apt-get install -y -qq \
    xorg \
    openbox \
    chromium \
    python3 \
    python3-pip \
    python3-flask \
    python3-websocket \
    xdotool \
    unclutter \
    fonts-dejavu \
    curl \
    git \
    sudo

# ── 2b. Blacklist SD card controller (causes log spam on some hardware)
if [ ! -f /etc/modprobe.d/cbtv-blacklist.conf ]; then
    echo "blacklist sdhci" > /etc/modprobe.d/cbtv-blacklist.conf
    echo "blacklist sdhci_pci" >> /etc/modprobe.d/cbtv-blacklist.conf
    echo "blacklist sdhci_acpi" >> /etc/modprobe.d/cbtv-blacklist.conf
    update-initramfs -u -k all
    NEEDS_REBOOT=true
fi


# ── 3. Create cbtv user ──────────────────────────────────────
echo "[3/9] Creating cbtv user..."
if ! id "$CBTV_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$CBTV_USER"
    usermod -aG video,audio,input "$CBTV_USER"
    printf '%s ALL=(ALL) NOPASSWD: /usr/sbin/reboot, /usr/sbin/shutdown\nDefaults:%s !requiretty\n' "$CBTV_USER" "$CBTV_USER" > /etc/sudoers.d/cbtv
    chmod 440 /etc/sudoers.d/cbtv
    NEEDS_REBOOT=true
fi

# ── 4. Auto-login on tty1 ────────────────────────────────────
echo "[4/9] Configuring auto-login..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $CBTV_USER --noclear %I \$TERM
EOF

# ── 5. Auto-start X + Openbox on login ──────────────────────
echo "[5/9] Configuring X auto-start..."
cat > /home/$CBTV_USER/.bash_profile << 'EOF'
# Auto-start X on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
EOF
chown $CBTV_USER:$CBTV_USER /home/$CBTV_USER/.bash_profile

# ── 6. Openbox autostart ─────────────────────────────────────
echo "[6/9] Configuring Openbox..."
rm -f /etc/asound.conf
mkdir -p /home/$CBTV_USER/.config/openbox
cat > /home/$CBTV_USER/.config/openbox/autostart << EOF
# Auto-detect and set HDMI audio output on every boot
HDMI_LINE=\$(aplay -l 2>/dev/null | grep -i "hdmi" | grep "device" | head -1)
HDMI_CARD=\$(echo "\$HDMI_LINE" | sed 's/card \([0-9]*\):.*/\1/')
HDMI_DEV=\$(echo "\$HDMI_LINE" | sed 's/.*device \([0-9]*\):.*/\1/')
if [ -n "\$HDMI_CARD" ] && [ -n "\$HDMI_DEV" ]; then
  cat > /home/$CBTV_USER/.asoundrc << ASOUNDEOF
defaults.pcm.card \$HDMI_CARD
defaults.pcm.device \$HDMI_DEV
defaults.ctl.card \$HDMI_CARD
ASOUNDEOF
fi

# Hide cursor after 1s idle
unclutter -idle 1 -root &

# Disable screen blanking & DPMS
xset s off
xset -dpms
xset s noblank

# Keep display alive — reset screen saver every 4 minutes
while true; do xset s reset; sleep 240; done &

# Start the Stream CBTV control server
/usr/bin/python3 $CBTV_DIR/server.py &

# Wait for network — required for uBlock Origin to fetch on first boot
for i in \$(seq 1 30); do ping -c1 -W1 8.8.8.8 &>/dev/null && break; sleep 1; done

# Reset Chromium exit state so the restore prompt never appears
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/g; s/"exit_type":"Killed"/"exit_type":"Normal"/g; s/"exited_cleanly":false/"exited_cleanly":true/g' \
    /home/$CBTV_USER/.config/chromium/Default/Preferences 2>/dev/null || true

# Launch Chromium
sleep 2
chromium \\
    --no-first-run \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --disable-restore-session-state \\
    --autoplay-policy=no-user-gesture-required \\
    --disable-features=TranslateUI \\
    --remote-debugging-port=9222 \\
    --remote-allow-origins=http://localhost:9222 \\
    --start-fullscreen \\
    http://localhost:$SERVICE_PORT/tv &
EOF
chown -R $CBTV_USER:$CBTV_USER /home/$CBTV_USER/.config

# ── 7. Install Stream CBTV app ───────────────────────────────
echo "[7/9] Installing Stream CBTV app..."
mkdir -p $CBTV_DIR
cp server.py $CBTV_DIR/
cp -r templates $CBTV_DIR/
chown -R $CBTV_USER:$CBTV_USER $CBTV_DIR

# ── 8. Systemd service ───────────────────────────────────────
echo "[8/9] Creating systemd service..."
cat > /etc/systemd/system/cbtv.service << EOF
[Unit]
Description=Stream CBTV Control Server
After=network.target

[Service]
User=$CBTV_USER
WorkingDirectory=$CBTV_DIR
ExecStart=/usr/bin/python3 $CBTV_DIR/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cbtv.service

# ── 9. uBlock Origin for Chromium ───────────────────────────
echo "[9/9] Installing uBlock Origin..."
UBLOCK_DIR="/home/$CBTV_USER/.config/chromium/Default/Extensions/cjpalhdlnbpafiamejdnhcphjbkeiagm"
mkdir -p "$UBLOCK_DIR"
CHROMIUM_POLICIES_DIR="/etc/chromium/policies/managed"
mkdir -p "$CHROMIUM_POLICIES_DIR"
cat > "$CHROMIUM_POLICIES_DIR/cbtv.json" << 'EOF'
{
    "ExtensionInstallForcelist": [
        "cjpalhdlnbpafiamejdnhcphjbkeiagm;https://clients2.google.com/service/update2/crx"
    ],
    "AutoplayAllowed": true,
    "FullscreenAllowed": true,
    "DefaultPopupsSetting": 2
}
EOF

chown -R $CBTV_USER:$CBTV_USER /home/$CBTV_USER/.config 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           SETUP COMPLETE ✓           ║"
echo "╠══════════════════════════════════════╣"
echo "║  Control UI: http://<device-ip>:7777 ║"
echo "╚══════════════════════════════════════╝"
echo ""
if [ "$NEEDS_REBOOT" = "true" ]; then
    read -p "Reboot required. Reboot now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
else
    echo "No reboot needed — changes are live."
    systemctl restart cbtv 2>/dev/null || true
fi
