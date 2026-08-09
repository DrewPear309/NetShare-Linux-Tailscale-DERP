#!/usr/bin/env bash
# buzz-netshare.sh
#
# Launch Buzz Desktop through NetShare using proxychains4.
#
# Optional add-on for the netshare-tailscale-bridge project.
# Does not modify Tailscale, Firefox, SSH, or any VPS.
#
# Defaults:
#   NetShare host: 192.168.49.1
#   NetShare port: 8282
#
# Optional overrides:
#   NETSHARE_IP=192.168.49.1
#   NETSHARE_PORT=8282
#   BUZZ_APP=/path/to/Buzz.AppImage
#   BUZZ_RELAY_URL=wss://your-community.example

set -euo pipefail

NETSHARE_IP="${NETSHARE_IP:-192.168.49.1}"
NETSHARE_PORT="${NETSHARE_PORT:-8282}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/proxychains-buzz.conf"

find_buzz() {
    local candidates=(
        "${BUZZ_APP:-}"
        "$HOME/Desktop/Buzz_0.5.1_amd64.AppImage"
        "$HOME/Desktop/Buzz.AppImage"
        "$HOME/Applications/Buzz_0.5.1_amd64.AppImage"
        "$HOME/Applications/Buzz.AppImage"
    )

    local item
    for item in "${candidates[@]}"; do
        if [[ -n "$item" && -f "$item" ]]; then
            printf '%s\n' "$item"
            return 0
        fi
    done

    local found=""
    found="$(find "$HOME/Desktop" "$HOME/Applications" \
        -maxdepth 1 -type f -iname 'Buzz*.AppImage' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi

    return 1
}

echo "=== Buzz over NetShare ==="
echo "NetShare proxy: ${NETSHARE_IP}:${NETSHARE_PORT}"
echo

if ! command -v proxychains4 >/dev/null 2>&1; then
    echo "ERROR: proxychains4 is not installed." >&2
    echo "Install it with:" >&2
    echo "  sudo apt install proxychains4" >&2
    exit 1
fi

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: proxychains config not found:" >&2
    echo "  $CONF_FILE" >&2
    exit 1
fi

if ! BUZZ_PATH="$(find_buzz)"; then
    echo "ERROR: Buzz AppImage not found." >&2
    echo "Set BUZZ_APP explicitly, for example:" >&2
    echo '  BUZZ_APP="$HOME/Applications/Buzz.AppImage" ./buzz-netshare.sh' >&2
    exit 1
fi

if [[ ! -x "$BUZZ_PATH" ]]; then
    echo "Buzz AppImage is not executable yet. Fixing that..."
    chmod +x "$BUZZ_PATH"
fi

RUNTIME_CONF="$(mktemp)"
trap 'rm -f "$RUNTIME_CONF"' EXIT

sed \
    -e "s/__NETSHARE_IP__/${NETSHARE_IP}/g" \
    -e "s/__NETSHARE_PORT__/${NETSHARE_PORT}/g" \
    "$CONF_FILE" > "$RUNTIME_CONF"

echo "Buzz AppImage: $BUZZ_PATH"
if [[ -n "${BUZZ_RELAY_URL:-}" ]]; then
    echo "Relay override: $BUZZ_RELAY_URL"
fi
echo
echo "Launching Buzz through proxychains..."
echo

if [[ -n "${BUZZ_RELAY_URL:-}" ]]; then
    exec env BUZZ_RELAY_URL="$BUZZ_RELAY_URL" \
        proxychains4 -f "$RUNTIME_CONF" "$BUZZ_PATH"
else
    exec proxychains4 -f "$RUNTIME_CONF" "$BUZZ_PATH"
fi
