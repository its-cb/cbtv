#!/bin/bash
# ============================================================
#  Stream CBTV — Deploy Script (run from Mac)
#  Usage: bash deploy.sh <ip> <user> [wifi-ssid] [wifi-password]
#         bash deploy.sh user@ip [wifi-ssid] [wifi-password]
#  Example: bash deploy.sh 10.0.0.35 casey
#           bash deploy.sh casey@10.0.0.35 "MyNetwork" "MyPassword"
# ============================================================

ARG1=${1:?Usage: bash deploy.sh <ip> <user>  OR  bash deploy.sh user@ip}

# Accept either "user@ip" as one argument or ip + user as two arguments
if [[ "$ARG1" == *@* ]]; then
  USER="${ARG1%%@*}"
  IP="${ARG1##*@}"
  WIFI_SSID=${2:-}
  WIFI_PASS=${3:-}
else
  IP="$ARG1"
  USER=${2:?Usage: bash deploy.sh <ip> <user>  OR  bash deploy.sh user@ip}
  WIFI_SSID=${3:-}
  WIFI_PASS=${4:-}
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(dirname "$SCRIPT_DIR")"

# Write WiFi credentials into the project dir so they get bundled in the tar.
# setup.sh will consume and delete this file on the remote side.
if [ -n "$WIFI_SSID" ]; then
    printf 'WIFI_SSID=%s\nWIFI_PASS=%s\n' "$WIFI_SSID" "$WIFI_PASS" > "$SCRIPT_DIR/wifi.conf"
    echo "→ WiFi profile: $WIFI_SSID"
fi

echo ""
echo "╔══════════════════════════════════════╗"
echo "║       Stream CBTV Deploy             ║"
echo "╚══════════════════════════════════════╝"
echo ""

echo "→ Building archive..."
cd "$PROJECT"
COPYFILE_DISABLE=1 tar czf cbtv.tar.gz cbtv/ \
    --exclude "cbtv/deploy.sh" \
    --exclude "cbtv/.git" \
    --exclude "cbtv/.gitignore"
echo "  Done."

echo "→ Transferring to $USER@$IP..."
scp "$PROJECT/cbtv.tar.gz" "$USER@$IP:/tmp/"
echo "  Done."

echo "→ Running setup on $IP..."
SETUP_CMD="cd /tmp && tar --warning=no-unknown-keyword -xzf cbtv.tar.gz && cd /tmp/cbtv && tr -d \"\\015\" < setup.sh > /tmp/setup_clean.sh && cd /tmp/cbtv && bash /tmp/setup_clean.sh"
ssh -t "$USER@$IP" "sudo bash -c '$SETUP_CMD' || su - root -c '$SETUP_CMD'"

# Clean up local archive and any wifi credentials
rm -f "$PROJECT/cbtv.tar.gz"
rm -f "$SCRIPT_DIR/wifi.conf"
echo ""
