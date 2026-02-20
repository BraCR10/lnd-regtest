# Security

**Nothing is accessible from the internet except SSH (port 22).** Defense in depth:

| Layer | What it does |
|-------|--------------|
| **ufw** | Blocks all incoming traffic except SSH |
| **bind 127.0.0.1** | bitcoind, LND, RTL, Nostr relay, and Mostro only listen on localhost |
| **SSH tunnel** | The only way to reach RTL or any service remotely |

## Verifying

After setup, confirm no services are exposed to the internet:

```bash
# Should only show port 22 on 0.0.0.0 / *
ss -tlnp | grep -v 127.0.0
```

All Docker containers use `network_mode: host` and bind to `127.0.0.1`, so even without ufw, services are only reachable locally. The firewall adds a second layer of protection.
