# Using the server on your Mac from your phone

The desktop app's local server ("Start a new server on this computer") only
listens on `127.0.0.1`. To use it from the Android app, turn on access from
other devices and put it behind **your own HTTPS reverse proxy** (Caddy,
nginx, Nginx Proxy Manager on Unraid, SWAG, Traefik…).

```
phone ──HTTPS──▶ your proxy (matrix.example.com) ──HTTP──▶ Mac :8008 ──▶ Tuwunel 127.0.0.1:6167
                                                              └──────▶ crosschatd API (/_crosschat/v1)
```

## 1. On the Mac

Crosschat → **Settings → Server on this computer → Allow access from other devices**.

- Crosschat starts a second listener on **port 8008** (all interfaces, plain
  HTTP) and shows the addresses to point your proxy at, e.g.
  `http://192.168.1.20:8008`. Give the Mac a fixed IP (a DHCP reservation in
  your router): proxies in Docker usually can't resolve `Name.local`.
- Optional **Public URL** (e.g. `https://matrix.example.com`): served at
  `/.well-known/matrix/client`, so the phone can sign in with just the domain.
- What the listener exposes: the Matrix client-server API
  (`/_matrix/client/…`, `/_matrix/media/…`), `/.well-known/matrix/client`, and
  crosschatd's user API (`/_crosschat/v1/…`: networks, bridge sign-in,
  contact search; every call needs your Matrix access token). Federation,
  appservice and admin endpoints, the local-only `/_crosschat/v1/local/…`
  and the bridges themselves stay on `127.0.0.1`.
- The server name stays `localhost`. Your user ID is still
  `@devon:localhost`; only the URL differs. That's fine for clients.
- **The Mac must stay on and awake.** While this is on, Crosschat keeps it
  from idle-sleeping (`caffeinate -i`); closing the lid still sleeps it.
- **macOS firewall:** if it's on, macOS asks whether `crosschatd` may accept
  incoming connections. Choose **Allow**. (Locally signed builds can ask
  again after an update.)
- Don't forward port 8008 on your router. Only the proxy should reach it, and
  only over HTTPS from outside.

Saved in `crosschatd.toml`:

```toml
[remote_access]
enabled = true
address = "0.0.0.0"   # or one interface's IP
port = 8008
public_url = "https://matrix.example.com"
```

## 2. The reverse proxy

Point a DNS name at the proxy, get a certificate (Let's Encrypt), and forward
**the whole host** to `http://MAC_IP:8008`. WebSockets aren't needed.
Two settings matter:

- **Long timeouts**: `/sync` long-polls for up to ~30 s and bridge sign-in
  calls can take a minute. Use ≥ 5 minutes; don't buffer responses.
- **Large bodies**: photos and videos from the phone. Allow 100 MB (the
  server's own limit).

### Caddy

```caddy
matrix.example.com {
	reverse_proxy MAC_IP:8008 {
		flush_interval -1
		transport http {
			read_timeout 10m
		}
	}
	request_body {
		max_size 100MB
	}
}
```

### nginx / SWAG

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name matrix.example.com;
    # ssl_certificate / ssl_certificate_key …

    client_max_body_size 100M;

    location / {
        proxy_pass http://MAC_IP:8008;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
```

### Nginx Proxy Manager (Unraid)

*Hosts → Proxy Hosts → Add Proxy Host*

- **Details:** Domain `matrix.example.com`, Scheme `http`, Forward Hostname/IP
  `MAC_IP`, Forward Port `8008`. *Websockets Support* not needed;
  *Block Common Exploits* is fine.
- **SSL:** request a Let's Encrypt certificate, *Force SSL*, *HTTP/2*.
- **Advanced → Custom Nginx Configuration:**

  ```nginx
  client_max_body_size 100M;
  proxy_read_timeout 600s;
  proxy_send_timeout 600s;
  proxy_buffering off;
  proxy_request_buffering off;
  ```

Check it from any machine:

```bash
curl https://matrix.example.com/_matrix/client/versions      # JSON list of versions
curl https://matrix.example.com/.well-known/matrix/client    # {"m.homeserver":{"base_url":…}}
curl -o /dev/null -w '%{http_code}\n' https://matrix.example.com/_matrix/federation/v1/version   # 404
```

## 3. On the phone

Install the APK, open Crosschat → **Use an existing Matrix server**:

- **Homeserver:** `https://matrix.example.com` (or just `matrix.example.com`
  if you set the Public URL)
- **Username:** `@devon:localhost` (or `devon`)
- **Password:** the password of the account you created on the Mac

The phone never runs a server of its own. Bridged chats (Slack, Google
Messages, iMessage) come from the Mac; networks and bridge sign-in in
Settings go to the Mac's crosschatd through the same URL.

The proxy needs a certificate the phone trusts (Let's Encrypt is fine).
Plain `http://MAC_IP:8008` from the phone is not supported: Android blocks
cleartext traffic for the app.
