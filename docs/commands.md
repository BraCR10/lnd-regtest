# Useful commands

## lncli

Each LND node has its own RPC port:

```bash
# lnd1
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo

# lnd2
docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:10010 getinfo
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
cd ~/BTC/lnd && docker compose logs -f nostr-relay
```

## Mining blocks

Generate regtest blocks to confirm transactions:

```bash
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```

## Port verification

Confirm no services are exposed to the internet:

```bash
# Should only show port 22 on 0.0.0.0 / *
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
```
