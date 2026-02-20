# Prerequisites

## 1. Bitcoin Core

Download and install from: https://bitcoincore.org/en/download/

## 2. Configure Bitcoin Core for regtest

Create or edit `~/.bitcoin/bitcoin.conf`:

```ini
server=1
daemon=1
txindex=1
regtest=1

[regtest]
fallbackfee=0.0002
rpcport=18443
port=18444
bind=127.0.0.1
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=YOUR_USER
rpcpassword=YOUR_PASSWORD
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
```

> **Note:** `bind=127.0.0.1` ensures the P2P port (18444) only listens locally.

Start bitcoind:

```bash
bitcoind -regtest -daemon
```

Generate initial blocks (first time only):

```bash
bitcoin-cli -regtest createwallet "miner"
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 101 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```

## 3. Docker

Docker and Docker Compose must be installed: https://docs.docker.com/engine/install/

## 4. Firewall (recommended)

Only SSH should be accessible from outside:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw enable
```
