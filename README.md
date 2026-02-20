# LND Regtest Setup

Script automatizado que levanta 2 nodos Lightning Network (LND) en regtest, crea wallets, fondea desde bitcoind, abre un canal de 5 BTC y lo equilibra 2.5/2.5.

## Prerequisitos

### 1. Bitcoin Core

Descargar e instalar desde: https://bitcoincore.org/en/download/

### 2. Configurar Bitcoin Core para regtest

Crear o editar `~/.bitcoin/bitcoin.conf`:

```ini
server=1
daemon=1
txindex=1
regtest=1

[regtest]
fallbackfee=0.0002
rpcport=18443
port=18444
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcuser=TU_USUARIO
rpcpassword=TU_PASSWORD
zmqpubrawblock=tcp://127.0.0.1:28332
zmqpubrawtx=tcp://127.0.0.1:28333
```

Iniciar bitcoind:

```bash
bitcoind -regtest -daemon
```

Generar bloques iniciales (solo la primera vez):

```bash
bitcoin-cli -regtest createwallet "miner"
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 101 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```

### 3. Docker

Necesitas Docker y Docker Compose instalados.

```bash
sudo apt install docker.io docker-compose-v2
sudo usermod -aG docker $USER
```

## Configuracion

Editar las variables al inicio de `lnd-setup.sh` para que coincidan con tu `bitcoin.conf`:

```bash
BITCOIND_RPC_USER="TU_USUARIO"
BITCOIND_RPC_PASS="TU_PASSWORD"
```

## Uso

```bash
chmod +x lnd-setup.sh
./lnd-setup.sh
```

El script te pedira una contrasena para las wallets LND (minimo 8 caracteres).

## Que hace el script

| Paso | Descripcion |
|------|-------------|
| 1/9 | Instala `jq` y `curl` |
| 2/9 | Limpia entorno LND anterior (bitcoind **no se toca**) |
| 3/9 | Pide contrasena para las wallets |
| 4/9 | Genera `lnd.conf` y `docker-compose.yml` |
| 5/9 | Inicia 2 contenedores LND (`network_mode: host`) |
| 6/9 | Crea wallets via REST API y guarda las seed phrases |
| 7/9 | Activa auto-unlock y reinicia contenedores |
| 8/9 | Fondea wallets desde la wallet `miner` de bitcoind |
| 9/9 | Abre canal de 5 BTC entre lnd1 y lnd2, equilibra 2.5/2.5 |

## Estructura

```
~/BTC/lnd/
├── lnd-setup.sh
├── docker-compose.yml      # generado por el script
├── lnd1/
│   ├── lnd.conf            # generado
│   └── data/
│       ├── seed.txt        # 24 palabras mnemonic
│       └── wallet-password.txt
└── lnd2/
    ├── lnd.conf
    └── data/
        ├── seed.txt
        └── wallet-password.txt
```

## Puertos

| Servicio | lnd1 | lnd2 |
|----------|------|------|
| P2P | 9735 | 9736 |
| gRPC | 10009 | 10010 |
| REST | 8080 | 8081 |

## Comandos utiles

```bash
# lncli para cada nodo
docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:10009 getinfo
docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:10010 getinfo

# Ver logs
cd ~/BTC/lnd && docker compose logs -f

# Minar bloques
bitcoin-cli -regtest -rpcwallet=miner generatetoaddress 1 $(bitcoin-cli -regtest -rpcwallet=miner getnewaddress)
```
