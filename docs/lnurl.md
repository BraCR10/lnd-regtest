# LNURL and Lightning Address

## What is LNURL

[LNURL](https://github.com/lnurl/luds) is a UX protocol on top of Lightning Network that replaces single-use invoices with reusable interactions: pay, receive, authenticate — all from a static QR code or a fixed URL.

Main sub-protocols:

| Protocol | What it does |
|----------|-------------|
| **lnurl-pay** (LUD-06) | Sender scans a QR/link and the server generates a BOLT11 invoice on the spot |
| **lnurl-withdraw** | Receiver scans a QR and "withdraws" sats from a service |
| **lnurl-auth** | Passwordless login — signs with the node key |
| **lightning address** (LUD-16) | Human-readable address like `user@domain.com` that internally resolves to lnurl-pay |

## What is a Lightning Address

A Lightning Address works like an email address but for receiving Bitcoin. Instead of sharing a 200-character invoice, you share something like:

```
satoshi@yourdomain.com
```

When someone pays that address, their wallet internally:

1. Takes `satoshi@yourdomain.com` and makes a GET to `https://yourdomain.com/.well-known/lnurlp/satoshi`
2. Your server responds with JSON (callback URL, min/max amounts, metadata)
3. The wallet calls the callback with the chosen amount
4. Your server generates a BOLT11 invoice from your LND node and returns it
5. The wallet pays the invoice

```
Payer's wallet                        Your server + LND
       |                                      |
       |  GET /.well-known/lnurlp/satoshi      |
       |  -----------------------------------> |
       |                                      |
       |  { callback, minSendable, ... }       |
       |  <----------------------------------- |
       |                                      |
       |  GET callback?amount=50000            |
       |  -----------------------------------> |
       |                                      |
       |  { pr: "lnbc500n1..." }               |
       |  <----------------------------------- |
       |                                      |
       |  Pays the BOLT11 invoice              |
       |  -----------------------------------> |
```

## What you need

### 1. A domain

You need to buy a domain (can be from [Namecheap](https://www.namecheap.com/), Porkbun, Cloudflare, etc.). The domain is what goes after the `@` in your Lightning Address.

**All you do with the domain is point the DNS to your server** — no complex configuration, just an A record:

```
Type: A
Host: @    (or the subdomain you want)
Value: YOUR_VPS_IP
TTL: Automatic
```

If you want to use a subdomain (e.g. `ln.yourdomain.com`):

```
Type: A
Host: ln
Value: YOUR_VPS_IP
TTL: Automatic
```

### 2. HTTPS (SSL certificate)

LNURL requires HTTPS. This setup uses **nginx + certbot** (Let's Encrypt) on the host. The script installs both automatically in step 9.

### 3. An LNURL server (satdress)

[satdress](https://github.com/nbd-wtf/satdress) is a lightweight Lightning Address server. It runs as a Docker container, receives HTTP requests at `/.well-known/lnurlp/<username>`, and generates invoices from your LND node.

## How it's set up (step 9)

Step 9 of `setup.sh` is **conditional** — it runs if `LNURL_DOMAIN` or `RTL_DOMAIN` is set in `.env`. The LNURL/satdress part only runs if `LNURL_DOMAIN` is set:

```bash
# .env
LNURL_DOMAIN=yourdomain.com
LNURL_USERNAMES=admin         # optional, defaults to "admin"
```

What step 9 does (shared for all domains):

1. Installs nginx + certbot (skips if already installed)
2. Opens ports 80/443 in ufw

What step 9 does (when `LNURL_DOMAIN` is set):

3. Obtains an SSL certificate via `certbot certonly --nginx`
4. Writes an nginx reverse proxy config (HTTPS → satdress on `127.0.0.1:17422`)
5. Writes satdress `.env` and starts the satdress Docker container
6. Auto-registers `admin@yourdomain.com` via the satdress API, pointing to lnd1

If `RTL_DOMAIN` is also set, step 9 additionally obtains a cert and writes an nginx config for RTL (see [rtl.md](rtl.md)).

## Architecture

```
Internet (payer's wallet)
        |
        v
  nginx (ports 80/443, HTTPS)
        |
        v
  satdress (127.0.0.1:17422)
   /.well-known/lnurlp/*
        |
        v
  lnd1 (127.0.0.1:8080 REST)
   generates BOLT11 invoices
```

nginx runs on the host (not Docker) because it needs ports 80/443 and certbot integration. satdress runs in Docker with host networking, following the same pattern as lnd1/lnd2.

## Verification

```bash
# Check satdress is running
docker ps | grep satdress

# Check nginx config
sudo nginx -t

# Test the Lightning Address endpoint
curl -s https://yourdomain.com/.well-known/lnurlp/admin

# Expected response (LNURL-pay JSON):
# {"callback":"...","maxSendable":...,"minSendable":...,"metadata":"...","tag":"payRequest"}
```

## Manual registration

If auto-registration fails, you can register manually at `http://127.0.0.1:17422` in a browser (via SSH tunnel) or via the API:

```bash
MAC_HEX=$(docker exec lnd1 xxd -p -c 9999 /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon)
curl -X POST http://127.0.0.1:17422/grab \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=admin&kind=lnd&host=https://127.0.0.1:8080&key=${MAC_HEX}"
```
