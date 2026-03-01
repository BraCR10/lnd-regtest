# Useful commands

## MostriX

MostriX is the TUI client for interacting with Mostro. Launch it with:

```bash
mostrix
```

Use arrow keys to navigate tabs and lists, Enter to select, Q to quit. Toggle admin mode with M.

Configuration: `~/.mostrix/settings.toml`

## lncli

Each LND node has its own RPC port:

```bash
# lnd1
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo

# lnd2
docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:10010 getinfo

# lnd3
docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:10011 getinfo
```

Common commands:

```bash
# Wallet balance
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 walletbalance

# Channel balances
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 channelbalance

# List channels
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listchannels

# List peers
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 listpeers
```

## Logs

The setup script installs `mostro-logs` as a bash command. It shows the last 100 lines and follows new output in real time:

```bash
mostro-logs
```

For other services, use docker compose directly:

```bash
# All services
cd ~/BTC/lnd && docker compose logs -f

# Specific service
cd ~/BTC/lnd && docker compose logs -f rtl
cd ~/BTC/lnd && docker compose logs -f lnd1
cd ~/BTC/lnd && docker compose logs -f lnd3
cd ~/BTC/lnd && docker compose logs -f mostro
```

## Mining blocks

Generate regtest blocks to confirm transactions:

```bash
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```

## Port verification

Confirm no services are exposed to the internet:

```bash
# Without domains: should only show port 22
# With RTL_DOMAIN or LNURL_DOMAIN: also ports 80, 443 (nginx)
ss -tlnp | grep -v 127.0.0
```

## Docker management

```bash
# Restart all services
cd ~/BTC/lnd && docker compose restart

# Stop everything
cd ~/BTC/lnd && docker compose down

# Re-run setup from scratch
cd ~/BTC/lnd && ./setup.sh

# Re-run from a specific step (e.g., rebuild Mostro + MostriX only)
cd ~/BTC/lnd && ./setup.sh --from 7
```
