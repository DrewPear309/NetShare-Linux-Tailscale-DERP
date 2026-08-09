#!/usr/bin/env bash
# tailup.sh — Tailscale over NetShare (Joey only)
#
# Creates a temporary local DNS-over-HTTPS bridge that itself uses NetShare's
# HTTP CONNECT proxy, points the active NetShare Wi-Fi link at that local DNS
# bridge, and gives tailscaled HTTP(S)_PROXY settings through a systemd drop-in.
#
# NO VPS CHANGES. No sshd/firewall/ACL/grant changes.
#
# Usage:
#   ./tailup.sh
#   ./tailup.sh piper
#
# Optional overrides:
#   NETSHARE_IP=192.168.49.1 NETSHARE_PORT=8282 ./tailup.sh piper

set -euo pipefail

NETSHARE_IP="${NETSHARE_IP:-192.168.49.1}"
NETSHARE_PORT="${NETSHARE_PORT:-8282}"
PROXY_URL="http://${NETSHARE_IP}:${NETSHARE_PORT}"
TARGET="${1:-piper}"

DNS_IP="127.0.0.99"
DNS_PORT="53"
DOH_URL="https://cloudflare-dns.com/dns-query"

DROPIN_DIR="/etc/systemd/system/tailscaled.service.d"
DROPIN_FILE="${DROPIN_DIR}/90-netshare-proxy.conf"
DROPIN_MARKER="# Managed by tailup.sh"

DOH_SCRIPT="/run/netshare-doh-bridge.py"
DOH_UNIT="netshare-doh-bridge.service"
STATE_FILE="/run/netshare-tailscale.state"

echo "=== Tailscale over NetShare: UP ==="
echo "NetShare proxy: ${PROXY_URL}"
echo "DNS bridge:     ${DNS_IP}:${DNS_PORT} -> DoH via NetShare"
echo "Test target:    ${TARGET}"
echo

for cmd in curl systemctl tailscale resolvectl ip python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

echo "[1/8] Finding Joey's interface to the tablet..."
IFACE="$(
    ip route get "$NETSHARE_IP" 2>/dev/null |
    awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
)"
if [[ -z "${IFACE}" ]]; then
    echo "ERROR: Could not determine the interface used to reach ${NETSHARE_IP}." >&2
    echo "Make sure Joey is connected to the tablet hotspot." >&2
    exit 1
fi
echo "  Interface: ${IFACE}"

echo
echo "[2/8] Testing NetShare HTTP CONNECT..."
if ! curl --silent --show-error --fail \
    --connect-timeout 8 --max-time 20 \
    --proxy "$PROXY_URL" \
    "https://controlplane.tailscale.com/derpmap/default" \
    -o /dev/null; then
    echo "ERROR: Tailscale HTTPS did not work through ${PROXY_URL}." >&2
    exit 1
fi
echo "  PASS: Tailscale HTTPS works through NetShare."

echo
echo "[3/8] Installing temporary proxy-aware DNS bridge..."
cat >"/tmp/netshare-doh-bridge.$$.py" <<'PYEOF'
#!/usr/bin/env python3
import os
import socketserver
import struct
import urllib.request

LISTEN_IP = os.environ.get("NETSHARE_DNS_IP", "127.0.0.99")
LISTEN_PORT = int(os.environ.get("NETSHARE_DNS_PORT", "53"))
DOH_URL = os.environ.get("NETSHARE_DOH_URL", "https://cloudflare-dns.com/dns-query")
PROXY_URL = os.environ["NETSHARE_PROXY_URL"]

proxy = urllib.request.ProxyHandler({
    "http": PROXY_URL,
    "https": PROXY_URL,
})
opener = urllib.request.build_opener(proxy)

def doh_query(packet: bytes) -> bytes:
    req = urllib.request.Request(
        DOH_URL,
        data=packet,
        headers={
            "Content-Type": "application/dns-message",
            "Accept": "application/dns-message",
            "User-Agent": "netshare-doh-bridge/1.0",
        },
        method="POST",
    )
    with opener.open(req, timeout=15) as r:
        return r.read()

class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        try:
            reply = doh_query(data)
            sock.sendto(reply, self.client_address)
        except Exception as e:
            print(f"UDP query failed for {self.client_address}: {e}", flush=True)

class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            hdr = self.request.recv(2)
            if len(hdr) != 2:
                return
            length = struct.unpack("!H", hdr)[0]
            data = b""
            while len(data) < length:
                chunk = self.request.recv(length - len(data))
                if not chunk:
                    return
                data += chunk
            reply = doh_query(data)
            self.request.sendall(struct.pack("!H", len(reply)) + reply)
        except Exception as e:
            print(f"TCP query failed for {self.client_address}: {e}", flush=True)

class ThreadingUDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True

class ThreadingTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

if __name__ == "__main__":
    import threading
    udp = ThreadingUDPServer((LISTEN_IP, LISTEN_PORT), UDPHandler)
    tcp = ThreadingTCPServer((LISTEN_IP, LISTEN_PORT), TCPHandler)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    print(f"DNS bridge listening on {LISTEN_IP}:{LISTEN_PORT}; DoH={DOH_URL}; proxy={PROXY_URL}", flush=True)
    udp.serve_forever()
PYEOF

sudo install -m 0755 "/tmp/netshare-doh-bridge.$$.py" "$DOH_SCRIPT"
rm -f "/tmp/netshare-doh-bridge.$$.py"

# Stop a prior transient instance if present.
sudo systemctl stop "$DOH_UNIT" 2>/dev/null || true
sudo systemctl reset-failed "$DOH_UNIT" 2>/dev/null || true

sudo systemd-run \
    --unit="$DOH_UNIT" \
    --property=Type=simple \
    --property=Restart=on-failure \
    --property=RestartSec=2 \
    --setenv="NETSHARE_PROXY_URL=${PROXY_URL}" \
    --setenv="NETSHARE_DNS_IP=${DNS_IP}" \
    --setenv="NETSHARE_DNS_PORT=${DNS_PORT}" \
    --setenv="NETSHARE_DOH_URL=${DOH_URL}" \
    /usr/bin/python3 "$DOH_SCRIPT" >/dev/null

sleep 1
if ! sudo systemctl is-active --quiet "$DOH_UNIT"; then
    echo "ERROR: temporary DNS bridge did not start." >&2
    sudo journalctl -u "$DOH_UNIT" -n 20 --no-pager || true
    exit 1
fi
echo "  PASS: temporary DNS bridge is running."

echo
echo "[4/8] Routing this NetShare link's DNS through the bridge..."
# These are transient per-link settings. 'resolvectl revert <iface>' restores
# the network manager's normal DNS state.
sudo resolvectl dns "$IFACE" "$DNS_IP"
sudo resolvectl domain "$IFACE" '~.'
sudo resolvectl default-route "$IFACE" yes

cat <<EOF | sudo tee "$STATE_FILE" >/dev/null
IFACE=${IFACE}
NETSHARE_IP=${NETSHARE_IP}
NETSHARE_PORT=${NETSHARE_PORT}
EOF
sudo chmod 0600 "$STATE_FILE"

echo "  Testing system DNS..."
if ! resolvectl query controlplane.tailscale.com >/dev/null 2>&1; then
    echo "ERROR: system DNS still cannot resolve controlplane.tailscale.com." >&2
    echo "Rolling back DNS changes..."
    sudo resolvectl revert "$IFACE" || true
    sudo systemctl stop "$DOH_UNIT" || true
    sudo rm -f "$DOH_SCRIPT" "$STATE_FILE"
    exit 1
fi
echo "  PASS: system DNS now resolves through NetShare."

echo
echo "[5/8] Installing isolated tailscaled proxy drop-in..."
if sudo test -f "$DROPIN_FILE"; then
    if ! sudo grep -Fqx "$DROPIN_MARKER" "$DROPIN_FILE"; then
        echo "ERROR: ${DROPIN_FILE} already exists and is not ours." >&2
        exit 1
    fi
fi

sudo install -d -m 0755 "$DROPIN_DIR"
tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT
cat >"$tmpfile" <<EOF
$DROPIN_MARKER
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="http_proxy=${PROXY_URL}"
Environment="https_proxy=${PROXY_URL}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
Environment="no_proxy=localhost,127.0.0.1,::1"
EOF
sudo install -m 0644 "$tmpfile" "$DROPIN_FILE"

echo
echo "[6/8] Reloading systemd and restarting tailscaled..."
sudo systemctl daemon-reload
sudo systemctl restart tailscaled
sleep 3

echo
echo "[7/8] Tailscale status:"
tailscale status || true

echo
echo "[8/8] Connectivity checks:"
echo "--- netcheck ---"
tailscale netcheck || true
echo
echo "--- ping ${TARGET} ---"
tailscale ping --timeout=10s "$TARGET" || true

echo
echo "=== NetShare Tailscale mode prepared ==="
echo
echo "If Tailscale says 'Logged out', authenticate ONCE using the URL it prints."
echo "After authenticating, run:"
echo
echo "    tailscale status"
echo "    tailscale ping ${TARGET}"
echo
echo "A DERP/relay path is expected because NetShare does not provide normal UDP."
echo
echo "To restore Joey's normal networking later:"
echo
echo "    ./taildown.sh"
