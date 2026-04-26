#!/bin/bash
# ============================================================
#  Stream CBTV MIGRATION — rename streambox → cbtv on live device
#  Run as root
# ============================================================

set -e

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     Stream CBTV MIGRATION v2.0       ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. Stop service ──────────────────────────────────────────
echo "[1/8] Stopping streambox service..."
systemctl stop streambox.service 2>/dev/null || true
systemctl disable streambox.service 2>/dev/null || true

# ── 2. Disable X auto-start so session doesn't restart ──────
echo "[2/8] Disabling X auto-start temporarily..."
if [ -f /home/streambox/.bash_profile ]; then
    cp /home/streambox/.bash_profile /home/streambox/.bash_profile.bak
    echo "# disabled during migration" > /home/streambox/.bash_profile
fi

# ── 3. Kill all streambox processes then rename user ─────────
echo "[3/8] Renaming user streambox → cbtv..."
pkill -u streambox 2>/dev/null || true
sleep 3
if id streambox &>/dev/null && ! id cbtv &>/dev/null; then
    usermod -l cbtv streambox
    usermod -d /home/cbtv -m cbtv
    groupmod -n cbtv streambox
elif id cbtv &>/dev/null; then
    echo "  User cbtv already exists, skipping."
fi

# ── 4. Copy app to new directory ─────────────────────────────
echo "[4/8] Moving app to /opt/cbtv..."
if [ ! -d /opt/cbtv ]; then
    cp -r /opt/streambox /opt/cbtv
fi
chown -R cbtv:cbtv /opt/cbtv

# ── 5. Update sudoers ────────────────────────────────────────
echo "[5/8] Updating sudoers..."
echo "cbtv ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/shutdown" > /etc/sudoers.d/cbtv
rm -f /etc/sudoers.d/streambox

# ── 6. Restore and update bash_profile + Openbox autostart ──
echo "[6/8] Updating user config..."
cat > /home/cbtv/.bash_profile << 'EOF'
# Auto-start X on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
EOF
chown cbtv:cbtv /home/cbtv/.bash_profile
sed -i 's|/opt/streambox|/opt/cbtv|g' /home/cbtv/.config/openbox/autostart
sed -i 's|/home/streambox|/home/cbtv|g' /home/cbtv/.config/openbox/autostart
sed -i 's|/home/cbox|/home/cbtv|g' /home/cbtv/.config/openbox/autostart

# ── 7. Create new systemd service ───────────────────────────
echo "[7/8] Creating cbtv.service..."
cat > /etc/systemd/system/cbtv.service << 'EOF'
[Unit]
Description=Stream CBTV Control Server
After=network.target

[Service]
User=cbtv
WorkingDirectory=/opt/cbtv
ExecStart=/usr/bin/python3 /opt/cbtv/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cbtv.service

# ── 8. Rename Chromium policy + update auto-login ────────────
echo "[8/8] Finishing up..."
if [ -f /etc/chromium/policies/managed/streambox.json ]; then
    mv /etc/chromium/policies/managed/streambox.json \
       /etc/chromium/policies/managed/cbtv.json
fi
sed -i 's/--autologin streambox/--autologin cbtv/g' \
    /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null || true
systemctl daemon-reload

echo ""
echo "╔══════════════════════════════════════╗"
echo "║        MIGRATION COMPLETE ✓          ║"
echo "╠══════════════════════════════════════╣"
echo "║  Reboot to apply all changes.        ║"
echo "╚══════════════════════════════════════╝"
echo ""
read -p "Reboot now? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
