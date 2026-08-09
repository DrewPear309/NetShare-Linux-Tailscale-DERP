#!/usr/bin/env bash
# taildown.sh — Restore Joey after Tailscale-over-NetShare mode
#
# Removes ONLY the temporary NetShare DNS bridge, its transient resolver
# settings, and the tailscaled proxy drop-in created by tailup.sh.
#
# NO VPS CHANGES.

set -euo pipefail

DROPIN_DIR="/etc/systemd/system/tailscaled.service.d"
DROPIN_FILE="${DROPIN_DIR}/90-netshare-proxy.conf"
DROPIN_MARKER="# Managed by tailup.sh"

DOH_SCRIPT="/run/netshare-doh-bridge.py"
DOH_UNIT="netshare-doh-bridge.service"
STATE_FILE="/run/netshare-tailscale.state"

echo "=== Tailscale over NetShare: DOWN ==="
echo

for cmd in systemctl tailscale resolvectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

IFACE=""
if sudo test -f "$STATE_FILE"; then
    # Read only the IFACE value we wrote ourselves.
    IFACE="$(sudo awk -F= '$1=="IFACE"{print $2; exit}' "$STATE_FILE")"
fi

echo "[1/5] Restoring normal DNS for the NetShare link..."
if [[ -n "$IFACE" ]]; then
    if resolvectl status "$IFACE" >/dev/null 2>&1; then
        sudo resolvectl revert "$IFACE" || true
        echo "  Reverted transient DNS settings on: $IFACE"
    else
        echo "  Saved interface '$IFACE' is no longer present; nothing to revert."
    fi
else
    echo "  No saved NetShare interface state found."
fi

echo
echo "[2/5] Stopping temporary DNS-over-HTTPS bridge..."
sudo systemctl stop "$DOH_UNIT" 2>/dev/null || true
sudo systemctl reset-failed "$DOH_UNIT" 2>/dev/null || true
sudo rm -f "$DOH_SCRIPT" "$STATE_FILE"
echo "  DNS bridge stopped/removed."

echo
echo "[3/5] Removing NetShare proxy override from tailscaled..."
if sudo test -f "$DROPIN_FILE"; then
    if sudo grep -Fqx "$DROPIN_MARKER" "$DROPIN_FILE"; then
        sudo rm -f "$DROPIN_FILE"
        echo "  Removed: $DROPIN_FILE"
    else
        echo "ERROR: ${DROPIN_FILE} exists but was not created by tailup.sh." >&2
        echo "Refusing to remove it." >&2
        exit 1
    fi
else
    echo "  No NetShare tailscaled proxy override present."
fi
sudo rmdir "$DROPIN_DIR" 2>/dev/null || true

echo
echo "[4/5] Reloading systemd and restarting tailscaled normally..."
sudo systemctl daemon-reload
sudo systemctl restart tailscaled
sleep 2

echo
echo "[5/5] Current Tailscale status:"
tailscale status || true

echo
echo "=== Normal Joey Tailscale configuration restored ==="
echo
echo "You do NOT have to switch networks before running this script."
echo "If Joey remains on NetShare afterward, ordinary DNS/Tailscale may be offline"
echo "until you reconnect Joey to your regular hotspot or another normal network."
