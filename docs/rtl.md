# RTL (Ride The Lightning)

RTL is a web UI for managing Lightning nodes. After setup completes, it's available at:

```
http://127.0.0.1:3000
```

Both LND nodes are available in the UI via a dropdown selector. The RTL password defaults to your `WALLET_PASS`. Set `RTL_PASSWORD` in `.env` to use a different one.

## Accessing RTL

RTL binds to `127.0.0.1` by default (localhost only, not reachable from the internet). How you access it depends on where you're running the setup:

### Local machine

If you're running this on your own computer, just open `http://localhost:3000` in your browser. No extra steps needed.

### VPS — SSH tunnel (recommended)

The safest way to access RTL on a remote server. Nothing is exposed to the internet.

From your local machine, open the tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 user@your-vps-ip
```

Then open `http://localhost:3000` in your local browser. The tunnel stays open as long as the SSH session is active.

### VPS — Open port directly (not recommended)

You can bind RTL to `0.0.0.0` so it's accessible from the internet. **This exposes RTL to anyone** — only do this if you understand the risk and have additional protections (strong password, fail2ban, etc.).

To do this, edit `rtl/RTL-Config.json` after running the script and change:

```json
"host": "0.0.0.0"
```

Then allow the port through the firewall and restart:

```bash
sudo ufw allow 3000/tcp
cd ~/BTC/lnd && docker compose restart rtl
```

### VPS — Custom domain with reverse proxy

For production-like access with HTTPS and a domain name, you can put a reverse proxy (e.g. nginx, caddy, traefik) in front of RTL. The proxy handles TLS and public access while RTL stays on `127.0.0.1`.
