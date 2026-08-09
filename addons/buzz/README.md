# Buzz Desktop over NetShare 🐝

> Optional add-on for the **NetShare × Tailscale Bridge** project.

Buzz Desktop can behave differently from Firefox or other proxy-aware applications on a NetShare connection.

In testing, ordinary HTTPS downloads from Buzz worked through NetShare while the Buzz relay still reported:

```text
relay unreachable: network error
```

The relay itself was reachable. A direct test through NetShare successfully completed the HTTP CONNECT tunnel, TLS handshake, and WebSocket upgrade:

```text
HTTP/1.1 101 Switching Protocols
```

That pointed to a client-side issue: the Buzz relay networking path was not using the NetShare proxy even though other Buzz HTTPS traffic could.

The practical workaround is to launch Buzz through **ProxyChains-NG**.

## Files

```text
addons/
└── buzz/
    ├── README.md
    ├── buzz-netshare.sh
    └── proxychains-buzz.conf
```

This add-on is intentionally separate from the core project. It does **not** modify:

- Tailscale
- Firefox
- the NetShare/Tailscale DNS bridge
- SSH
- VPS configuration

It only changes **how Buzz is launched**.

## Requirements

Install ProxyChains-NG:

```bash
sudo apt install proxychains4
```

Make the launcher executable:

```bash
chmod +x buzz-netshare.sh
```

The default NetShare values are:

```text
Host: 192.168.49.1
Port: 8282
```

## Launch Buzz

From the `addons/buzz/` directory:

```bash
./buzz-netshare.sh
```

The launcher looks for a Buzz AppImage in common locations such as:

```text
~/Desktop/
~/Applications/
```

If it cannot find Buzz automatically, specify it:

```bash
BUZZ_APP="$HOME/Desktop/Buzz_0.5.1_amd64.AppImage" \
./buzz-netshare.sh
```

The script also makes the AppImage executable automatically if necessary.

## Different NetShare address or port

Override either value without editing the files:

```bash
NETSHARE_IP=192.168.49.1 \
NETSHARE_PORT=8282 \
./buzz-netshare.sh
```

## Optional relay override

Buzz's packaged client can be pointed at a relay with `BUZZ_RELAY_URL`, or the relay can be changed from inside Buzz.

For example:

```bash
BUZZ_RELAY_URL="wss://your-community.example" \
./buzz-netshare.sh
```

If the relay is already configured correctly inside Buzz, you do not need this.

## What the launcher does

```text
Buzz Desktop
     │
     ▼
ProxyChains-NG
     │
     ▼
NetShare HTTP CONNECT
192.168.49.1:8282
     │
     ▼
wss:// Buzz relay
```

`proxychains-buzz.conf` uses:

```text
strict_chain
proxy_dns
```

and an HTTP proxy entry.

ProxyChains-NG can redirect TCP connections from dynamically linked applications through HTTP or SOCKS proxies, which makes it useful for programs that do not expose reliable proxy settings of their own.

## Verify the relay independently

If Buzz still reports a relay error, first prove that NetShare can carry the relay WebSocket itself.

Replace the relay hostname below with yours:

```bash
curl -v \
  -x http://192.168.49.1:8282 \
  --http1.1 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: SGVsbG9CdXp6MTIzNDU2Nw==" \
  https://your-community.example/
```

A response containing:

```text
HTTP/1.1 101 Switching Protocols
```

means the HTTP proxy, TLS connection, and WebSocket upgrade all succeeded.

If that test works but Buzz still says the relay is unreachable, the problem is likely in the application's own networking path rather than NetShare itself.

## Troubleshooting

<details>
<summary><strong>Buzz downloads models or updates, but the relay still fails</strong></summary>

That was the exact behavior that led to this add-on.

Ordinary HTTPS traffic can honor proxy environment settings while a separate relay/WebSocket implementation bypasses them. Launching the app through ProxyChains catches ordinary TCP socket connections at a lower layer.

</details>

<details>
<summary><strong>Permission denied when starting the AppImage</strong></summary>

Make it executable:

```bash
chmod +x /path/to/Buzz.AppImage
```

The included launcher will also do this automatically once it finds the AppImage.

</details>

<details>
<summary><strong>ProxyChains says it cannot connect</strong></summary>

First verify NetShare itself:

```bash
curl -x http://192.168.49.1:8282 https://api.ipify.org
```

If that fails, solve the NetShare connection before troubleshooting Buzz.

</details>

<details>
<summary><strong>Buzz is using the wrong relay</strong></summary>

The packaged Buzz app can use `BUZZ_RELAY_URL` or a relay selected inside the app.

Launch with an explicit relay if needed:

```bash
BUZZ_RELAY_URL="wss://your-community.example" \
./buzz-netshare.sh
```

</details>

## Caveat

ProxyChains-NG works by intercepting networking calls in dynamically linked applications. Its maintainers describe the technique as pragmatic and note that compatibility is not guaranteed with every complex application. It is TCP-only.

For Buzz's secure WebSocket relay connection, TCP is exactly what is needed here.

## Why keep this as an add-on?

The core NetShare/Tailscale project solves the general network problem.

This recipe solves a more specific application problem:

```text
NetShare works.
The relay works.
Buzz doesn't use the proxy path.
Wrap Buzz instead of redesigning the network.
```

That keeps the base setup small while leaving room for other application-specific recipes later.
