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
# Install chrony first — bypass both valid-until AND valid-after signature checks
# because the clock may be skewed in either direction on a fresh install
APT_NOSIG="-o Acquire::Check-Valid-Until=false -o Acquire::Check-Valid-After=false"
apt-get $APT_NOSIG update -qq
apt-get install -y -qq chrony
systemctl enable chrony
systemctl start chrony
chronyc makestep 2>/dev/null || true
# Wait until chrony confirms the clock is actually synced (up to 30s)
for i in $(seq 1 30); do
    chronyc tracking 2>/dev/null | grep -q "^Reference ID" && break
    sleep 1
done

# ── 1. System update ─────────────────────────────────────────
echo "[1/9] Updating system packages..."
apt-get $APT_NOSIG update -qq && apt-get upgrade -y -qq

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
    pulseaudio \
    pulseaudio-utils \
    cec-utils \
    fonts-dejavu \
    curl \
    git \
    sudo \
    sqlite3 \
    wpasupplicant

# ── 2b. WiFi profile (optional — bundled by deploy.sh if SSID was provided) ─
if [ -f wifi.conf ]; then
    # shellcheck source=/dev/null
    source wifi.conf
    rm -f wifi.conf
    if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
        WIFI_IFACE=$(ip link show | awk -F': ' '/^[0-9]+: w/{gsub(/@.*/,"",$2); print $2; exit}')
        if [ -n "$WIFI_IFACE" ]; then
            echo "  Configuring WiFi: $WIFI_SSID on $WIFI_IFACE"
            wpa_passphrase "$WIFI_SSID" "$WIFI_PASS" > /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
            chmod 600 /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
            systemctl enable wpa_supplicant@${WIFI_IFACE}
            if ! grep -q "$WIFI_IFACE" /etc/network/interfaces 2>/dev/null; then
                cat >> /etc/network/interfaces << EOF

allow-hotplug $WIFI_IFACE
iface $WIFI_IFACE inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant-${WIFI_IFACE}.conf
EOF
            fi
            echo "  WiFi profile saved. Will connect automatically when in range."
        else
            echo "  No WiFi interface detected — skipping WiFi config."
        fi
    fi
fi

# ── 2d. Blacklist SD card controller (causes log spam on some hardware)
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
    printf '%s ALL=(ALL) NOPASSWD: /usr/sbin/reboot, /usr/sbin/shutdown, /usr/bin/systemctl restart cbtv\nDefaults:%s !requiretty\n' "$CBTV_USER" "$CBTV_USER" > /etc/sudoers.d/cbtv
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

# Start PulseAudio and route to HDMI (Chromium uses PulseAudio, not ALSA directly)
pulseaudio --start 2>/dev/null || true
sleep 1
HDMI_SINK=\$(pactl list sinks short 2>/dev/null | grep -i hdmi | awk '{print \$2}' | head -1)
if [ -n "\$HDMI_SINK" ]; then
  pactl set-default-sink "\$HDMI_SINK" 2>/dev/null || true
  pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null || true
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

# ── 10. Pi-hole (local DNS filter / optional network-wide blocker) ─
if command -v pihole &>/dev/null; then
    echo "[10/10] Pi-hole already installed — checking for updates..."
    pihole -up 2>/dev/null || true
else
echo "[10/10] Installing Pi-hole..."

# Detect primary network interface and its IP/CIDR
PIHOLE_IFACE=$(ip route | awk '/default/ {print $5; exit}')
PIHOLE_IPV4=$(ip -4 addr show "$PIHOLE_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)

# Write unattended install config
mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf << EOF
PIHOLE_INTERFACE=$PIHOLE_IFACE
IPV4_ADDRESS=$PIHOLE_IPV4
IPV6_ADDRESS=
PIHOLE_DNS_1=8.8.8.8
PIHOLE_DNS_2=8.8.4.4
QUERY_LOGGING=true
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSMASQ_LISTENING=local
WEBPASSWORD=
BLOCKING_ENABLED=true
EOF

# If systemd-resolved is running its stub listener it will clash with Pi-hole on port 53
if systemctl is-active systemd-resolved &>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/pihole.conf << 'EOF'
[Resolve]
DNS=127.0.0.1
DNSStubListener=no
EOF
    systemctl restart systemd-resolved
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

# Run Pi-hole unattended installer
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

# Set a readable random password (adjective-noun-number) so the web UI isn't read-only
ADJS=(calm cool dark fast flat gold grey hard keen long mild neat rich slow soft warm wide)
NOUNS=(bay cave crest dawn field frost gate hill lake mist peak pine reef ridge rock shore slope stone)
PIHOLE_PASS="${ADJS[$((RANDOM % ${#ADJS[@]}))]}-${NOUNS[$((RANDOM % ${#NOUNS[@]}))]}-$((RANDOM % 900 + 100))"
pihole setpassword "$PIHOLE_PASS" 2>/dev/null || pihole -a -p "$PIHOLE_PASS" 2>/dev/null || true

# Add Hagezi adlists to gravity.db (Pi-hole installs sqlite3 as a dependency)
# Do this before switching DNS so the gravity pull uses the existing working DNS
sqlite3 /etc/pihole/gravity.db << 'SQLEOF'
INSERT OR IGNORE INTO adlist (address, enabled, date_added, comment) VALUES
    ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/multi.txt',      1, strftime('%s','now'), 'Hagezi Multi'),
    ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/popupads.txt',   1, strftime('%s','now'), 'Hagezi Popup Ads'),
    ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt',        1, strftime('%s','now'), 'Hagezi Threat Intelligence Feeds'),
    ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt',       1, strftime('%s','now'), 'Hagezi Fake');
SQLEOF
pihole -g

# Point this machine's DNS at its own Pi-hole.
# dhcpcd overwrites /etc/resolv.conf each time the network connects.
# Fix: suppress the DHCP-provided DNS option and write our nameserver to
# /etc/resolv.conf.head, which dhcpcd always prepends verbatim.
if systemctl is-active systemd-resolved &>/dev/null; then
    systemctl restart systemd-resolved
elif command -v dhcpcd &>/dev/null; then
    grep -q 'nohook resolv.conf' /etc/dhcpcd.conf 2>/dev/null || \
        echo 'nohook resolv.conf' >> /etc/dhcpcd.conf
    rm -f /etc/resolv.conf.head
    chattr -i /etc/resolv.conf 2>/dev/null || true
    echo 'nameserver 127.0.0.1' > /etc/resolv.conf
    chattr +i /etc/resolv.conf
    systemctl restart dhcpcd 2>/dev/null || true
else
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

echo "  Pi-hole admin: http://$(echo "$PIHOLE_IPV4" | cut -d/ -f1):8080/admin"
echo "  Pi-hole password: $PIHOLE_PASS"

fi # end Pi-hole install block

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           SETUP COMPLETE ✓           ║"
echo "╠══════════════════════════════════════╣"
echo "║  Control UI: http://<device-ip>:7777 ║"
echo "║  Pi-hole:    http://<device-ip>:8080/admin ║"
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
