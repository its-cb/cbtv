#!/bin/bash
# ============================================================
#  Stream CBTV — Deploy Script (run from Mac)
#  Usage: bash deploy.sh <device-ip> [username]
#  Example: bash deploy.sh 192.168.86.40
#           bash deploy.sh 192.168.86.40 logic
# ============================================================

IP=${1:?Usage: bash deploy.sh <device-ip> [username]}
USER=${2:-cbtv}
PROJECT="/Users/cbaldwin/Documents/Home/Stream CBTV"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Stream CBTV Deploy             ║"
echo "╚══════════════════════════════════════╝"
echo ""

echo "→ Building zip..."
cd "$PROJECT"
zip -r cbtv.zip cbtv/ -q --exclude "cbtv/deploy.sh" --exclude "cbtv/.git/*" --exclude "cbtv/.gitignore"
echo "  Done."

echo "→ Transferring to $USER@$IP..."
scp "$PROJECT/cbtv.zip" $USER@$IP:/tmp/
echo "  Done."

echo ""
echo "Transfer complete. SSH in and run:"
echo ""
echo "  su -"
echo "  cd /tmp && unzip -o cbtv.zip && cd cbtv && bash setup.sh"
echo ""
