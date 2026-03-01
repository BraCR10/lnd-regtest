# Mostro Regtest

Automated setup for 3 LND regtest nodes (triangle topology), RTL web UI, and [Mostro](https://github.com/MostroP2P/mostro) P2P exchange — all on localhost.

## Quick start

1. Install [prerequisites](docs/prerequisites.md) (Bitcoin Core, Docker, firewall)
2. Configure and run:

```bash
cp .env.example .env
nano .env   # set BITCOIND_RPC_USER and BITCOIND_RPC_PASS
chmod +x setup.sh
./setup.sh

# Re-run from a specific step (skips earlier steps)
./setup.sh --from 7
```

The script will prompt for a wallet password (min 8 chars), or set `WALLET_PASS` in `.env` to skip the prompt.

## What the script does

| Step | Description |
|------|-------------|
| 1/9 | Verifies prerequisites (docker, bitcoind, bitcoin-cli) |
| 2/9 | Installs `jq` and `curl` (skips if already installed) |
| 3/9 | Cleans previous environment (bitcoind is **not touched**) |
| 4/9 | Asks for wallet password (or loads from `.env`) |
| 5/9 | Writes LND + RTL configs, `docker-compose.yml`, starts LND |
| 6/9 | Creates wallets, enables auto-unlock, starts RTL |
| 7/9 | Sets up Mostro + MostriX: loads/prompts/generates Nostr key, starts Mostro on lnd1, builds MostriX TUI |
| 8/9 | Funds wallets, opens and balances channels (triangle: lnd1↔lnd2, lnd3↔lnd1, lnd3↔lnd2) |
| 9/9 | Domains + HTTPS via nginx (skipped if neither `RTL_DOMAIN` nor `LNURL_DOMAIN` is set) |

## Documentation

- [Prerequisites](docs/prerequisites.md) — Bitcoin Core, Docker, firewall setup
- [Configuration](docs/configuration.md) — `.env` options, directory structure, ports
- [RTL (Ride The Lightning)](docs/rtl.md) — web UI access methods (local, SSH tunnel, reverse proxy)
- [Mostro + MostriX](docs/mostro.md) — P2P exchange setup, MostriX TUI client, Nostr key options
- [Security](docs/security.md) — defense-in-depth, port verification
- [Commands](docs/commands.md) — lncli, logs, mining, Docker management
- [LNURL and Lightning Address](docs/lnurl.md) — domain, DNS, how the protocol works

## Useful commands

```bash
# MostriX — TUI client for Mostro (orders, trades, admin)
mostrix

# lncli (each node has its own RPC port: 10009, 10010, 10011)
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo
docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:10011 listchannels

# Logs
cd ~/BTC/lnd && docker compose logs -f mostro

# Mine blocks
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```

See [docs/commands.md](docs/commands.md) for more.
