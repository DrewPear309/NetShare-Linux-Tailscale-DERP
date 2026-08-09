#!/bin/bash
# netshare-setup.sh — Stable NetShare setup for Joey on Linux Mint
# Configures TTL normalization + Firefox SOCKS5 + remote DNS + HTTP/3 off.
# Does NOT modify Tailscale or any VPS.

set -euo pipefail

NETSHARE_IP="192.168.49.1"
NETSHARE_PORT="8282"
MANAGED_BEGIN='// --- BEGIN NETSHARE MANAGED SETTINGS ---'
MANAGED_END='// --- END NETSHARE MANAGED SETTINGS ---'

echo "=== NetShare / Mint Stable Setup ==="
echo "NetShare SOCKS5: ${NETSHARE_IP}:${NETSHARE_PORT}"

echo
echo "[1/5] Ensuring outgoing TTL is set to 65..."
if sudo iptables -t mangle -C POSTROUTING -j TTL --ttl-set 65 2>/dev/null; then
    echo "  TTL=65 rule already present"
else
    sudo iptables -t mangle -A POSTROUTING -j TTL --ttl-set 65
    echo "  Added TTL=65 rule"
fi

echo
echo "[2/5] Ensuring TTL rule survives reboot..."
if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    echo "  Installing iptables-persistent..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi

if [ ! -x /usr/sbin/netfilter-persistent ]; then
    echo "  Repairing iptables-persistent installation..."
    sudo dpkg --configure -a
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y iptables-persistent
fi

sudo /usr/sbin/netfilter-persistent save >/dev/null
echo "  Saved firewall rules"

echo
echo "[3/5] Locating Firefox profile..."
PROFILE_DIR=""
for candidate in ~/.mozilla/firefox/*.default-release ~/.mozilla/firefox/*.default; do
    if [ -d "$candidate" ]; then
        PROFILE_DIR="$candidate"
        break
    fi
done

if [ -z "$PROFILE_DIR" ]; then
    echo "  ERROR: No Firefox profile found. Open Firefox once, then re-run this script." >&2
    exit 1
fi

echo "  Using: $PROFILE_DIR"
USER_JS="$PROFILE_DIR/user.js"
BACKUP_DIR="$PROFILE_DIR/netshare-backups"
mkdir -p "$BACKUP_DIR"

if [ -f "$USER_JS" ]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    cp "$USER_JS" "$BACKUP_DIR/user.js.$STAMP.bak"
    echo "  Backed up existing user.js"
fi

echo
echo "[4/5] Updating Firefox NetShare settings..."
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

if [ -f "$USER_JS" ]; then
    awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' "$USER_JS" > "$TMP_FILE"
fi

cat >> "$TMP_FILE" <<EOF2
$MANAGED_BEGIN
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "$NETSHARE_IP");
user_pref("network.proxy.socks_port", $NETSHARE_PORT);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "localhost,127.0.0.1,::1");
user_pref("privacy.resistFingerprinting", true);
user_pref("network.http.http3.enable", false);
$MANAGED_END
EOF2

mv "$TMP_FILE" "$USER_JS"
trap - EXIT
echo "  Firefox settings written to: $USER_JS"

echo
echo "[5/5] Testing NetShare SOCKS5 path..."
if curl --silent --show-error --max-time 12 \
    --proxy "socks5h://${NETSHARE_IP}:${NETSHARE_PORT}" \
    https://api.ipify.org > /tmp/netshare-ip.$$; then
    PUBLIC_IP=$(cat /tmp/netshare-ip.$$)
    rm -f /tmp/netshare-ip.$$
    echo "  PASS: Internet reachable through NetShare"
    echo "  Public IP: $PUBLIC_IP"
else
    rm -f /tmp/netshare-ip.$$ 2>/dev/null || true
    echo "  FAIL: Could not reach the Internet through NetShare SOCKS5" >&2
    echo "  Confirm Joey is connected to the tablet hotspot and NetShare is running." >&2
    exit 1
fi

echo
echo "=== Setup complete ==="
echo "Restart Firefox for the managed settings to take effect."
echo "No Tailscale settings were changed. No VPS settings were changed."
