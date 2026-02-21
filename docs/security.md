# Security

Defense in depth — only what's necessary is exposed to the internet:

| Layer | What it does |
|-------|--------------|
| **ufw** | Blocks all incoming traffic except SSH (22) and, if Lightning Address is enabled, HTTP/HTTPS (80/443) |
| **bind 127.0.0.1** | bitcoind, LND, RTL, Mostro, and satdress only listen on localhost |
| **nginx** | The only service on 0.0.0.0 — reverse proxies HTTPS to satdress, nothing else |
| **SSH tunnel** | The only way to reach RTL or internal services remotely |

## What's exposed to the internet

| Port | Service | When |
|------|---------|------|
| 22 | SSH | Always |
| 80 | nginx (HTTP → HTTPS redirect) | Only if `LNURL_DOMAIN` is set |
| 443 | nginx (HTTPS → satdress) | Only if `LNURL_DOMAIN` is set |

nginx only proxies to satdress (`127.0.0.1:17422`), which only serves the `/.well-known/lnurlp/` endpoint for Lightning Address. Your LND nodes, RTL, Mostro, bitcoind, and macaroons are **not** reachable through nginx.

## Without Lightning Address

If `LNURL_DOMAIN` is not set, nothing changes — only port 22 is open. No nginx, no satdress, no ports 80/443.

## Verifying

```bash
# Check what's listening on public interfaces (not 127.0.0.1)
ss -tlnp | grep -v 127.0.0

# Without LNURL: should only show port 22
# With LNURL: should show ports 22, 80, 443 (nginx)

# Verify nginx only serves the LNURL endpoint
curl -s https://yourdomain.com/.well-known/lnurlp/admin   # should work
curl -s https://yourdomain.com/v1/getinfo                  # should NOT return LND data
```

All Docker containers use `network_mode: host` and bind to `127.0.0.1`, so even without ufw, services are only reachable locally. The firewall adds a second layer of protection.
