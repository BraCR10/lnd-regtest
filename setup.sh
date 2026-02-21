#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  setup.sh — Mostro Regtest
#
#  Spins up 3 LND nodes on regtest using Docker (host networking),
#  creates wallets, funds them from bitcoind, opens channels (triangle
#  topology), launches RTL (Ride The Lightning) to manage all nodes, and
#  starts Mostro (P2P Lightning exchange over Nostr) connected to lnd1.
#
#  Configuration: copy .env.example to .env and fill in your values.
#  Run ./setup.sh --help for usage information.
###############################################################################

# ── Usage ─────────────────────────────────────────────────────────────────────

show_usage() {
  cat <<'USAGE'
Usage: ./setup.sh [--help]

Mostro Regtest — sets up 3 LND regtest nodes + RTL + Mostro with Docker.

Steps:
  1. Verifies prerequisites (docker, bitcoind, bitcoin-cli)
  2. Installs dependencies (jq, curl)
  3. Cleans previous environment (bitcoind is NOT touched)
  4. Prompts for a wallet password
  5. Writes configs, docker-compose.yml, and starts LND containers
  6. Creates wallets, enables auto-unlock, starts RTL
  7. Loads/prompts/generates Nostr key, configures and starts Mostro on lnd1
  8. Funds wallets and opens a balanced channel
  9. Domains + HTTPS via nginx (only if RTL_DOMAIN or LNURL_DOMAIN is set)

Configuration:
  Copy .env.example to .env and set BITCOIND_RPC_USER and BITCOIND_RPC_PASS
  to match your bitcoin.conf. See .env.example for all options.

Options:
  --help, -h    Show this help message
USAGE
}

# Handle --help before loading config
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_usage
  exit 0
fi

# ── Config ────────────────────────────────────────────────────────────────────
# Load user settings from .env and apply defaults for anything unset.
# Only BITCOIND_RPC_USER and BITCOIND_RPC_PASS are required — everything else
# has sensible defaults so the script works out of the box.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${SCRIPT_DIR}"

if [[ ! -f "${BASE_DIR}/.env" ]]; then
  echo "Error: ${BASE_DIR}/.env not found."
  echo "Copy .env.example to .env and fill in your values:"
  echo "  cp .env.example .env"
  exit 1
fi
# shellcheck source=/dev/null
source "${BASE_DIR}/.env"

: "${BITCOIND_RPC_USER:?Set BITCOIND_RPC_USER in .env}"
: "${BITCOIND_RPC_PASS:?Set BITCOIND_RPC_PASS in .env}"

if [[ "${BITCOIND_RPC_USER}" == "your_rpc_user" || "${BITCOIND_RPC_PASS}" == "your_rpc_password" ]]; then
  echo "Error: .env still has placeholder values."
  echo "Edit .env and set BITCOIND_RPC_USER and BITCOIND_RPC_PASS to match your bitcoin.conf."
  exit 1
fi

BITCOIND_HOST="${BITCOIND_HOST:-127.0.0.1}"
BITCOIND_RPC_PORT="${BITCOIND_RPC_PORT:-18443}"
MINER_WALLET="${MINER_WALLET:-miner}"
LND_IMAGE="${LND_IMAGE:-lightninglabs/lnd:v0.20.1-beta}"
FUND_LND1_BTC="${FUND_LND1_BTC:-8}"
FUND_LND2_BTC="${FUND_LND2_BTC:-3}"
FUND_LND3_BTC="${FUND_LND3_BTC:-6}"
CHANNEL_SATS="${CHANNEL_SATS:-500000000}"
REBALANCE_SATS="${REBALANCE_SATS:-250000000}"
LND3_CHANNEL_SATS="${LND3_CHANNEL_SATS:-250000000}"

RTL_IMAGE="${RTL_IMAGE:-shahanafarooqui/rtl:v0.15.8}"
RTL_PORT="${RTL_PORT:-3000}"
RTL_DOMAIN="${RTL_DOMAIN:-}"

MOSTRO_IMAGE="${MOSTRO_IMAGE:-mostrop2p/mostro:latest}"
MOSTRO_RELAYS="${MOSTRO_RELAYS:-wss://nos.lol,wss://relay.mostro.network}"

ZMQ_BLOCK="tcp://${BITCOIND_HOST}:28332"
ZMQ_TX="tcp://${BITCOIND_HOST}:28333"

NODES=(lnd1 lnd2 lnd3)
declare -A PORTS=(
  [lnd1_listen]=9735  [lnd1_rpc]=10009  [lnd1_rest]=8080
  [lnd2_listen]=9736  [lnd2_rpc]=10010  [lnd2_rest]=8081
  [lnd3_listen]=9737  [lnd3_rpc]=10011  [lnd3_rest]=8082
)
declare -A FUND_BTC=(
  [lnd1]="${FUND_LND1_BTC}"
  [lnd2]="${FUND_LND2_BTC}"
  [lnd3]="${FUND_LND3_BTC}"
)

LNURL_DOMAIN="${LNURL_DOMAIN:-}"
LNURL_USERNAMES="${LNURL_USERNAMES:-admin}"
SATDRESS_PORT="${SATDRESS_PORT:-17422}"

WALLET_PASS="${WALLET_PASS:-}"
MOSTRO_NSEC=""
MOSTRO_NPUB=""
MOSTRO_HEX=""

# ── Helpers ───────────────────────────────────────────────────────────────────
# log/ok/fail — consistent coloured output for step progress.
# lncli/bcli  — wrappers that hide repetitive flags.
# mine_blocks — generates regtest blocks via the miner wallet.
# wait_ready / wait_wallet_unlocker — poll loops for LND startup stages.

log()  { echo -e "\n\033[1;34m[$1]\033[0m $2"; }
ok()   { echo -e "  \033[1;32m✔\033[0m $1"; }
fail() { echo -e "  \033[1;31m✘\033[0m $1"; exit 1; }

lncli() {
  local node="$1"; shift
  docker exec "$node" lncli --network=regtest \
    --rpcserver="127.0.0.1:${PORTS[${node}_rpc]}" "$@" 2>/dev/null | tr -d '\r'
}

bcli() { bitcoin-cli -regtest "$@"; }

mine_blocks() {
  local addr
  addr="$(bcli -rpcwallet="${MINER_WALLET}" getnewaddress)"
  bcli -rpcwallet="${MINER_WALLET}" generatetoaddress "$1" "$addr" >/dev/null
}

wait_ready() {
  local node="$1" i=0
  echo "  Waiting for ${node}..."
  while (( i < 120 )); do
    if docker exec "$node" lncli --network=regtest \
         --rpcserver="127.0.0.1:${PORTS[${node}_rpc]}" getinfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( i++ ))
  done
  return 1
}

wait_wallet_unlocker() {
  local port="$1" i=0
  while (( i < 60 )); do
    local resp
    resp="$(curl -sk "https://127.0.0.1:${port}/v1/genseed" 2>/dev/null)" || true
    if echo "$resp" | jq -e '.cipher_seed_mnemonic' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    (( i++ ))
  done
  return 1
}

# Generate lnd.conf for a node. All listeners bind to 127.0.0.1 because we use
# host networking — without this, LND would listen on 0.0.0.0 and be reachable
# from the internet. The optional $extra arg adds wallet-unlock-password-file
# after the first run so LND auto-unlocks on restart.
write_lnd_conf() {
  local node="$1" extra="${2:-}"
  cat > "${BASE_DIR}/${node}/lnd.conf" <<EOF
[Application Options]
alias=${node}
debuglevel=info
listen=127.0.0.1:${PORTS[${node}_listen]}
rpclisten=127.0.0.1:${PORTS[${node}_rpc]}
restlisten=127.0.0.1:${PORTS[${node}_rest]}
${extra}

[Bitcoin]
bitcoin.regtest=1
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=${BITCOIND_HOST}:${BITCOIND_RPC_PORT}
bitcoind.rpcuser=${BITCOIND_RPC_USER}
bitcoind.rpcpass=${BITCOIND_RPC_PASS}
bitcoind.zmqpubrawblock=${ZMQ_BLOCK}
bitcoind.zmqpubrawtx=${ZMQ_TX}

[protocol]
protocol.wumbo-channels=1
EOF
}

# Generate RTL-Config.json with both LND nodes. RTL also binds to 127.0.0.1
# for the same host-networking reason. Each node gets its own macaroon path
# so RTL can switch between them via the UI dropdown.
write_rtl_config() {
  local rtl_pass="${RTL_PASSWORD:-${WALLET_PASS}}"
  mkdir -p "${BASE_DIR}/rtl/database"
  cat > "${BASE_DIR}/rtl/RTL-Config.json" <<EOF
{
  "multiPass": "${rtl_pass}",
  "port": "${RTL_PORT}",
  "host": "127.0.0.1",
  "defaultNodeIndex": 1,
  "dbDirectoryPath": "/RTL/database",
  "SSO": {
    "rtlSSO": 0,
    "rtlCookiePath": "",
    "logoutRedirectLink": ""
  },
  "nodes": [
    {
      "index": 1,
      "lnNode": "lnd1",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd1"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "TEAL",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd1_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    },
    {
      "index": 2,
      "lnNode": "lnd2",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd2"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "PURPLE",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd2_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    },
    {
      "index": 3,
      "lnNode": "lnd3",
      "lnImplementation": "LND",
      "authentication": {
        "macaroonPath": "/macaroons/lnd3"
      },
      "settings": {
        "userPersona": "OPERATOR",
        "themeMode": "NIGHT",
        "themeColor": "INDIGO",
        "channelBackupPath": "",
        "logLevel": "ERROR",
        "lnServerUrl": "https://127.0.0.1:${PORTS[lnd3_rest]}",
        "fiatConversion": false,
        "unannouncedChannels": false
      }
    }
  ]
}
EOF
}


# Generate Mostro settings.toml. Points at lnd1's gRPC and external relays.
# TLS cert and admin macaroon are copied from lnd1 in step 7.
write_mostro_config() {
  mkdir -p "${BASE_DIR}/mostro/lnd"

  # Build TOML relays array from MOSTRO_RELAYS
  local relays_toml=""
  if [[ -n "${MOSTRO_RELAYS}" ]]; then
    IFS=',' read -ra relay_list <<< "${MOSTRO_RELAYS}"
    for r in "${relay_list[@]}"; do
      r="$(echo "$r" | xargs)"  # trim whitespace
      [[ -z "$r" ]] && continue
      [[ -n "$relays_toml" ]] && relays_toml+=", "
      relays_toml+="'${r}'"
    done
  fi

  cat > "${BASE_DIR}/mostro/settings.toml" <<EOF
[lightning]
lnd_cert_file = '/config/lnd/tls.cert'
lnd_macaroon_file = '/config/lnd/admin.macaroon'
lnd_grpc_host = 'https://127.0.0.1:${PORTS[lnd1_rpc]}'
invoice_expiration_window = 3600
hold_invoice_cltv_delta = 144
hold_invoice_expiration_window = 300
payment_attempts = 3
payment_retries_interval = 60

[nostr]
nsec_privkey = '${MOSTRO_NSEC}'
relays = [${relays_toml}]

[mostro]
fee = 0
max_routing_fee = 0.001
max_order_amount = 1000000
min_payment_amount = 100
expiration_hours = 24
max_expiration_days = 15
expiration_seconds = 900
user_rates_sent_interval_seconds = 3600
publish_relays_interval = 60
pow = 0
publish_mostro_info_interval = 300
bitcoin_price_api_url = "https://api.yadio.io"
fiat_currencies_accepted = ['USD', 'EUR', 'ARS', 'CUP']
max_orders_per_response = 10
dev_fee_percentage = 0.30

[database]
url = "sqlite:///config/mostro.db"

[expiration]
order_days = 30
dispute_days = 90
fee_audit_days = 365

[rpc]
enabled = false
listen_address = "127.0.0.1"
port = 50051
EOF
}

# Generate nginx config for LNURL reverse proxy. HTTPS terminates here and
# proxies to satdress on 127.0.0.1:SATDRESS_PORT. Certbot manages the certs.
write_nginx_config() {
  sudo tee /etc/nginx/sites-available/lnurl >/dev/null <<EOF
server {
    listen 80;
    server_name ${LNURL_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${LNURL_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${LNURL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${LNURL_DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${SATDRESS_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
}

# Generate nginx config for RTL reverse proxy. HTTPS terminates here and
# proxies to RTL on 127.0.0.1:RTL_PORT. Includes WebSocket headers since
# RTL uses WebSockets for real-time updates.
write_rtl_nginx_config() {
  sudo tee /etc/nginx/sites-available/rtl >/dev/null <<EOF
server {
    listen 80;
    server_name ${RTL_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${RTL_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${RTL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${RTL_DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:${RTL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
}

# Generate satdress .env file. satdress reads its config from environment
# variables. The SECRET is randomly generated for HMAC signing.
write_satdress_env() {
  mkdir -p "${BASE_DIR}/satdress/data"
  local secret
  secret="$(openssl rand -hex 32)"
  cat > "${BASE_DIR}/satdress/.env" <<EOF
PORT=${SATDRESS_PORT}
DOMAIN=${LNURL_DOMAIN}
HOST=127.0.0.1
SECRET=${secret}
SITE_NAME=Mostro Regtest
SITE_OWNER_NAME=${LNURL_USERNAMES%%,*}
SITE_OWNER_URL=https://${LNURL_DOMAIN}
EOF
  chmod 600 "${BASE_DIR}/satdress/.env"
}

generate_nostr_keys() {
  echo "  Building rana (Nostr key generator)... this may take a few minutes on first run"
  local build_dir
  build_dir="$(mktemp -d)"
  cat > "${build_dir}/Dockerfile" <<'DOCKERFILE'
FROM rust:1.84-slim AS builder
RUN apt-get update && apt-get install -y cmake build-essential pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
RUN cargo install rana --locked
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libssl3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /usr/local/cargo/bin/rana /usr/local/bin/rana
ENTRYPOINT ["rana"]
DOCKERFILE

  if ! docker build -t rana -f "${build_dir}/Dockerfile" "${build_dir}" -q >/dev/null; then
    rm -rf "${build_dir}"
    fail "Failed to build rana Docker image — check Docker daemon and internet connectivity"
  fi
  rm -rf "${build_dir}"
  ok "rana image ready"

  echo "  Generating Nostr keypair..."
  docker rm -f rana-gen >/dev/null 2>&1 || true
  docker run -d --name rana-gen rana --difficulty 1 >/dev/null
  sleep 8

  local output
  output="$(docker logs rana-gen 2>&1)"
  docker rm -f rana-gen >/dev/null 2>&1

  MOSTRO_NSEC="$(echo "$output" | grep -oP 'nsec1[a-z0-9]+' | head -1)"
  MOSTRO_NPUB="$(echo "$output" | grep -oP 'npub1[a-z0-9]+' | head -1)"
  MOSTRO_HEX="$(echo "$output" | grep -oP '(?<=Hex public key:\s{3})[0-9a-f]+' | head -1)"

  if [[ -z "$MOSTRO_NSEC" || -z "$MOSTRO_NPUB" ]]; then
    fail "Could not generate Nostr keys — rana output: ${output}"
  fi
}

create_wallet_rest() {
  local node="$1"
  local rest_port="${PORTS[${node}_rest]}"
  local data_dir="${BASE_DIR}/${node}/data"

  echo "  Waiting for WalletUnlocker on ${node}..."
  wait_wallet_unlocker "$rest_port" || fail "${node} WalletUnlocker not responding"

  local seed_response
  if ! seed_response="$(curl -sk --connect-timeout 10 --max-time 30 "https://127.0.0.1:${rest_port}/v1/genseed")"; then
    fail "${node}: curl failed reaching LND REST API on port ${rest_port} — is lnd running?"
  fi
  local mnemonic
  mnemonic="$(echo "$seed_response" | jq -c '.cipher_seed_mnemonic')"

  if [[ "$mnemonic" == "null" || -z "$mnemonic" ]]; then
    fail "${node}: could not generate seed — ${seed_response}"
  fi

  echo "$seed_response" | jq -r '.cipher_seed_mnemonic[]' > "${data_dir}/seed.txt"
  chmod 600 "${data_dir}/seed.txt"

  local pass_b64
  pass_b64="$(echo -n "$WALLET_PASS" | base64)"

  local init_response
  if ! init_response="$(curl -sk --connect-timeout 10 --max-time 30 -X POST "https://127.0.0.1:${rest_port}/v1/initwallet" \
    -d "{\"wallet_password\":\"${pass_b64}\",\"cipher_seed_mnemonic\":${mnemonic}}")"; then
    fail "${node}: curl failed during wallet init on port ${rest_port}"
  fi

  if echo "$init_response" | jq -e '.admin_macaroon' >/dev/null 2>&1; then
    ok "${node} wallet created — seed at ${node}/data/seed.txt"
  else
    fail "${node}: error creating wallet — ${init_response}"
  fi
}

# ── Steps ─────────────────────────────────────────────────────────────────────

###############################################################################
#  STEP 1 — Preflight checks
#  Fail fast if Docker or bitcoind aren't available. Running the full setup
#  only to fail midway wastes time and leaves partial state to clean up.
###############################################################################
step_preflight() {
  log "1/9" "Preflight checks"

  if ! command -v docker &>/dev/null; then
    fail "docker is not installed (sudo apt install docker.io)"
  fi
  if ! docker info &>/dev/null; then
    fail "Docker daemon is not running (sudo systemctl start docker)"
  fi
  ok "Docker available"

  if ! command -v bitcoin-cli &>/dev/null; then
    fail "bitcoin-cli not found — install Bitcoin Core"
  fi
  ok "bitcoin-cli available"

  if ! bcli getblockchaininfo &>/dev/null; then
    fail "bitcoind is not reachable (is it running with -regtest?)"
  fi
  ok "bitcoind reachable"
}

###############################################################################
#  STEP 2 — Dependencies
#  jq is needed to parse LND REST API JSON responses; curl to call them.
#  Both are lightweight and safe to auto-install.
###############################################################################
step_deps() {
  log "2/9" "Checking dependencies (jq, curl)"

  local missing=()
  for cmd in jq curl; do
    if command -v "$cmd" &>/dev/null; then
      ok "${cmd} already installed"
    else
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "  Installing ${missing[*]} (requires sudo to apt-get install)"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "${missing[*]} installed"
  fi
}

###############################################################################
#  STEP 3 — Clean environment (bitcoind untouched)
#  Remove all containers, volumes, and generated configs so we start fresh.
#  bitcoind is NOT touched — it keeps its chain, wallets, and mined blocks.
#  LND data dirs may be owned by root (Docker), so we use an alpine container
#  to delete them reliably.
###############################################################################
step_clean() {
  log "3/9" "Cleaning environment (bitcoind NOT touched)"

  docker compose -f "${BASE_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
  docker rm -f "${NODES[@]}" rtl mostro satdress 2>/dev/null || true

  for node in "${NODES[@]}"; do
    if [[ -d "${BASE_DIR}/${node}" ]]; then
      docker run --rm -v "${BASE_DIR}/${node}:/cleanup" alpine \
        rm -rf /cleanup/data /cleanup/lnd.conf 2>/dev/null || true
      rm -rf "${BASE_DIR:?}/${node}" 2>/dev/null || true
    fi
  done
  rm -rf "${BASE_DIR}/rtl" "${BASE_DIR}/mostro" "${BASE_DIR}/satdress" 2>/dev/null || true
  rm -f "${BASE_DIR}/docker-compose.yml" 2>/dev/null || true

  for node in "${NODES[@]}"; do
    mkdir -p "${BASE_DIR}/${node}/data"
  done
  ok "Directories clean"
}

###############################################################################
#  STEP 4 — Ask wallet password
#  The same password is used for both LND wallets and (by default) RTL login.
#  If WALLET_PASS is already set in .env, skip the interactive prompt so the
#  script can run unattended.
###############################################################################
step_password() {
  log "4/9" "Wallet password for LND"

  if [[ -n "${WALLET_PASS:-}" ]] && (( ${#WALLET_PASS} >= 8 )); then
    ok "Password loaded from .env"
    return
  fi

  while true; do
    echo
    read -s -p "  Enter password (min 8 chars): " WALLET_PASS
    echo
    read -s -p "  Confirm password: " pass_confirm
    echo

    if (( ${#WALLET_PASS} < 8 )); then
      echo -e "  \033[1;31m✘\033[0m Minimum 8 characters — try again"
      continue
    fi
    if [[ "$WALLET_PASS" != "$pass_confirm" ]]; then
      echo -e "  \033[1;31m✘\033[0m Passwords do not match — try again"
      continue
    fi

    ok "Password accepted"
    break
  done
}

###############################################################################
#  STEP 5 — Write configs + start LND containers
#  Generate all config files and docker-compose.yml, then start only the LND
#  containers. RTL and the relay start later (step 6) because they need
#  macaroon files that don't exist until wallets are created.
###############################################################################
step_configs_and_start() {
  log "5/9" "Writing configs and starting LND containers"

  for node in "${NODES[@]}"; do
    write_lnd_conf "$node"
  done
  ok "LND configs written"

  write_rtl_config
  ok "RTL config written"

  cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  lnd1:
    image: ${LND_IMAGE}
    container_name: lnd1
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd1/data:/root/.lnd
      - ./lnd1/lnd.conf:/root/.lnd/lnd.conf:ro

  lnd2:
    image: ${LND_IMAGE}
    container_name: lnd2
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd2/data:/root/.lnd
      - ./lnd2/lnd.conf:/root/.lnd/lnd.conf:ro

  lnd3:
    image: ${LND_IMAGE}
    container_name: lnd3
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./lnd3/data:/root/.lnd
      - ./lnd3/lnd.conf:/root/.lnd/lnd.conf:ro

  rtl:
    image: ${RTL_IMAGE}
    container_name: rtl
    restart: unless-stopped
    network_mode: host
    environment:
      RTL_CONFIG_PATH: /RTL
    volumes:
      - ./rtl/RTL-Config.json:/RTL/RTL-Config.json
      - ./rtl/database:/RTL/database
      - ./lnd1/data/data/chain/bitcoin/regtest:/macaroons/lnd1:ro
      - ./lnd2/data/data/chain/bitcoin/regtest:/macaroons/lnd2:ro
      - ./lnd3/data/data/chain/bitcoin/regtest:/macaroons/lnd3:ro

  mostro:
    image: ${MOSTRO_IMAGE}
    container_name: mostro
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./mostro:/config
EOF

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    cat >> "${BASE_DIR}/docker-compose.yml" <<EOF

  satdress:
    image: jaonoctus/satdress
    container_name: satdress
    restart: unless-stopped
    network_mode: host
    env_file:
      - ./satdress/.env
    working_dir: /data
    volumes:
      - ./satdress/data:/data
EOF
  fi
  ok "docker-compose.yml written"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d lnd1 lnd2 lnd3
  sleep 3
  ok "lnd1, lnd2, and lnd3 running"
}

###############################################################################
#  STEP 6 — Create wallets + enable auto-unlock + start RTL & relay
#  Create wallets via REST API, then rewrite lnd.conf with the auto-unlock
#  password file and restart. This two-phase approach is needed because LND
#  only exposes the WalletUnlocker gRPC before a wallet exists. After restart,
#  macaroons are available and RTL + relay can start.
###############################################################################
step_wallets_and_unlock() {
  log "6/9" "Creating wallets, enabling auto-unlock, starting RTL"

  for node in "${NODES[@]}"; do
    create_wallet_rest "$node"
  done

  for node in "${NODES[@]}"; do
    echo -n "${WALLET_PASS}" > "${BASE_DIR}/${node}/data/wallet-password.txt"
    chmod 600 "${BASE_DIR}/${node}/data/wallet-password.txt"
    write_lnd_conf "$node" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"
  done

  docker compose -f "${BASE_DIR}/docker-compose.yml" restart lnd1 lnd2 lnd3
  sleep 5

  for node in "${NODES[@]}"; do
    wait_ready "$node" || fail "${node} not responding after restart"
  done
  ok "All nodes unlocked and ready"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d rtl
  ok "RTL started on http://127.0.0.1:${RTL_PORT}"
}

###############################################################################
#  STEP 7 — Configure Nostr key and start Mostro
#  Mostro needs a Nostr identity. We support three paths: key from .env,
#  interactive paste, or auto-generation with rana. After the key is set,
#  we copy lnd1's TLS cert and admin macaroon so Mostro can talk to it.
###############################################################################
step_mostro() {
  log "7/9" "Setting up Mostro (P2P exchange on lnd1)"

  mkdir -p "${BASE_DIR}/mostro"

  if [[ -n "${MOSTRO_NSEC_PRIVKEY:-}" ]]; then
    # Option 1: key from .env
    MOSTRO_NSEC="${MOSTRO_NSEC_PRIVKEY}"
    ok "Nostr private key loaded from .env"
  else
    # Option 2: ask the user
    echo
    read -p "  Enter your Nostr private key (nsec1...) or press Enter to generate one: " user_nsec
    if [[ -n "$user_nsec" ]]; then
      MOSTRO_NSEC="${user_nsec}"
      ok "Nostr private key provided"
    else
      # Option 3: generate with rana
      generate_nostr_keys
    fi
  fi

  echo "${MOSTRO_NSEC}" > "${BASE_DIR}/mostro/nostr-private.txt"
  chmod 600 "${BASE_DIR}/mostro/nostr-private.txt"
  ok "Private key saved to mostro/nostr-private.txt"

  write_mostro_config
  ok "Mostro settings.toml written"

  if ! docker cp lnd1:/root/.lnd/tls.cert "${BASE_DIR}/mostro/lnd/tls.cert"; then
    fail "Could not copy tls.cert from lnd1 — is the container running? (docker ps)"
  fi
  if ! docker cp lnd1:/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon "${BASE_DIR}/mostro/lnd/admin.macaroon"; then
    fail "Could not copy admin.macaroon from lnd1 — wallet may not have been created"
  fi
  chmod -R a+r "${BASE_DIR}/mostro/lnd"
  chmod a+rwx "${BASE_DIR}/mostro"
  ok "LND credentials copied for Mostro"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d mostro
  sleep 3
  ok "Mostro started (connected to lnd1)"

  if [[ -n "${MOSTRO_NPUB}" ]]; then
    echo
    echo -e "  \033[1;33mMostro public key (npub):\033[0m"
    echo -e "  \033[1;32m${MOSTRO_NPUB}\033[0m"
    if [[ -n "${MOSTRO_HEX}" ]]; then
      echo -e "  \033[1;33mMostro public key (hex):\033[0m"
      echo -e "  \033[1;32m${MOSTRO_HEX}\033[0m"
    fi
    echo
  fi
}

###############################################################################
#  STEP 8 — Fund wallets + open channels (triangle topology)
#  Send on-chain BTC from bitcoind's miner wallet to all LND nodes, open a
#  balanced channel lnd1↔lnd2, then open channels from lnd3→lnd1 and lnd3→lnd2.
#  This creates a triangle topology for richer routing.
###############################################################################
step_fund_and_channel() {
  log "8/9" "Funding wallets and opening channels"

  if ! bcli listwallets | jq -e ".[] | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
    if bcli listwalletdir | jq -e ".wallets[].name | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
      bcli loadwallet "${MINER_WALLET}" >/dev/null
    else
      bcli createwallet "${MINER_WALLET}" >/dev/null
    fi
  fi

  for node in "${NODES[@]}"; do
    local addr
    addr="$(lncli "$node" newaddress p2wkh | jq -r '.address')"
    bcli -rpcwallet="${MINER_WALLET}" sendtoaddress "$addr" "${FUND_BTC[$node]}" >/dev/null
  done

  mine_blocks 6
  sleep 3
  ok "lnd1 received ${FUND_BTC[lnd1]} BTC, lnd2 received ${FUND_BTC[lnd2]} BTC, lnd3 received ${FUND_BTC[lnd3]} BTC"

  # ── lnd1↔lnd2 balanced channel ──
  local pub2
  pub2="$(lncli lnd2 getinfo | jq -r '.identity_pubkey')"
  lncli lnd1 connect "${pub2}@127.0.0.1:${PORTS[lnd2_listen]}" >/dev/null 2>&1 || true
  sleep 2

  lncli lnd1 openchannel --node_key="${pub2}" --local_amt="${CHANNEL_SATS}" >/dev/null
  ok "lnd1↔lnd2 channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5

  local invoice
  invoice="$(lncli lnd2 addinvoice --amt="${REBALANCE_SATS}" --memo="rebalance" | jq -r '.payment_request')"
  lncli lnd1 payinvoice --force "${invoice}" >/dev/null
  ok "lnd1↔lnd2 channel balanced ~2.5 BTC each side"

  # ── lnd3 channels (2.5 BTC to lnd1, 2.5 BTC to lnd2) ──
  local pub1
  pub1="$(lncli lnd1 getinfo | jq -r '.identity_pubkey')"

  lncli lnd3 connect "${pub1}@127.0.0.1:${PORTS[lnd1_listen]}" >/dev/null 2>&1 || true
  lncli lnd3 connect "${pub2}@127.0.0.1:${PORTS[lnd2_listen]}" >/dev/null 2>&1 || true
  sleep 2

  lncli lnd3 openchannel --node_key="${pub1}" --local_amt="${LND3_CHANNEL_SATS}" >/dev/null
  ok "lnd3→lnd1 channel opened (pending confirmation)"

  echo "  Mining blocks to confirm change before second channel..."
  mine_blocks 6
  sleep 3

  lncli lnd3 openchannel --node_key="${pub2}" --local_amt="${LND3_CHANNEL_SATS}" >/dev/null
  ok "lnd3→lnd2 channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5
}

###############################################################################
#  STEP 9 — Domains + HTTPS (conditional)
#  Sets up nginx + certbot for any configured domains. RTL_DOMAIN gets a
#  reverse proxy to RTL; LNURL_DOMAIN gets satdress for Lightning Address.
#  Skipped entirely if neither domain is set in .env.
###############################################################################
step_domains() {
  log "9/9" "Domains + HTTPS (nginx + certbot)"

  if [[ -z "${RTL_DOMAIN}" && -z "${LNURL_DOMAIN}" ]]; then
    ok "Skipped — neither RTL_DOMAIN nor LNURL_DOMAIN set in .env"
    return
  fi

  [[ -n "${RTL_DOMAIN}" ]] && echo "  RTL domain: ${RTL_DOMAIN}"
  [[ -n "${LNURL_DOMAIN}" ]] && echo "  LNURL domain: ${LNURL_DOMAIN}"

  # ── Install nginx + certbot if not present ──
  local to_install=()
  command -v nginx &>/dev/null || to_install+=(nginx)
  command -v certbot &>/dev/null || to_install+=(certbot python3-certbot-nginx)

  if (( ${#to_install[@]} > 0 )); then
    echo "  Installing ${to_install[*]} (requires sudo to apt-get install)"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${to_install[@]}" >/dev/null
    ok "${to_install[*]} installed"
  else
    ok "nginx and certbot already installed"
  fi

  # ── Open ports 80/443 in ufw ──
  if command -v ufw &>/dev/null; then
    echo "  Opening firewall ports 80 and 443 (requires sudo for ufw)"
    sudo ufw allow 80/tcp >/dev/null 2>&1 || true
    sudo ufw allow 443/tcp >/dev/null 2>&1 || true
    ok "Firewall: ports 80 and 443 open"
  fi

  # ── RTL domain ──
  if [[ -n "${RTL_DOMAIN}" ]]; then
    if [[ ! -d "/etc/letsencrypt/live/${RTL_DOMAIN}" ]]; then
      echo "  Obtaining SSL certificate for ${RTL_DOMAIN} (requires sudo for certbot)"
      sudo certbot certonly --nginx -d "${RTL_DOMAIN}" \
        --non-interactive --agree-tos -m "admin@${RTL_DOMAIN}"
      ok "SSL certificate obtained for ${RTL_DOMAIN}"
    else
      ok "SSL certificate already exists for ${RTL_DOMAIN}"
    fi

    echo "  Writing nginx config for ${RTL_DOMAIN} (requires sudo to write /etc/nginx)"
    write_rtl_nginx_config
    sudo ln -sf /etc/nginx/sites-available/rtl /etc/nginx/sites-enabled/rtl
    ok "nginx config written for ${RTL_DOMAIN}"
  fi

  # ── LNURL domain ──
  if [[ -n "${LNURL_DOMAIN}" ]]; then
    if [[ ! -d "/etc/letsencrypt/live/${LNURL_DOMAIN}" ]]; then
      echo "  Obtaining SSL certificate for ${LNURL_DOMAIN} (requires sudo for certbot)"
      sudo certbot certonly --nginx -d "${LNURL_DOMAIN}" \
        --non-interactive --agree-tos -m "admin@${LNURL_DOMAIN}"
      ok "SSL certificate obtained for ${LNURL_DOMAIN}"
    else
      ok "SSL certificate already exists for ${LNURL_DOMAIN}"
    fi

    echo "  Writing nginx config for ${LNURL_DOMAIN} (requires sudo to write /etc/nginx)"
    write_nginx_config
    sudo ln -sf /etc/nginx/sites-available/lnurl /etc/nginx/sites-enabled/lnurl
    ok "nginx config written for ${LNURL_DOMAIN}"

    # ── Write satdress config and start container ──
    write_satdress_env
    ok "satdress .env written"

    docker compose -f "${BASE_DIR}/docker-compose.yml" up -d satdress
    sleep 3

    # Wait for satdress to respond
    local i=0
    while (( i < 30 )); do
      if curl -s "http://127.0.0.1:${SATDRESS_PORT}" >/dev/null 2>&1; then
        break
      fi
      sleep 1
      (( i++ ))
    done
    if (( i >= 30 )); then
      fail "satdress not responding on 127.0.0.1:${SATDRESS_PORT}"
    fi
    ok "satdress running on 127.0.0.1:${SATDRESS_PORT}"

    # ── Register Lightning Addresses ──
    local mac_hex
    mac_hex="$(docker exec lnd1 xxd -p -c 9999 /root/.lnd/data/chain/bitcoin/regtest/admin.macaroon 2>/dev/null)" \
      || fail "Could not read admin macaroon from lnd1"

    IFS=',' read -ra lnurl_users <<< "${LNURL_USERNAMES}"
    for uname in "${lnurl_users[@]}"; do
      uname="$(echo "$uname" | xargs)"  # trim whitespace
      [[ -z "$uname" ]] && continue

      local reg_resp
      reg_resp="$(curl -s -X POST "http://127.0.0.1:${SATDRESS_PORT}/grab" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "name=${uname}&kind=lnd&host=https://127.0.0.1:${PORTS[lnd1_rest]}&key=${mac_hex}" \
        2>/dev/null)" || true

      if echo "$reg_resp" | grep -q '"name":"'"${uname}"'"'; then
        ok "Lightning Address registered: ${uname}@${LNURL_DOMAIN}"
      else
        echo "  Warning: ${uname} registration may have failed"
        echo "  You can register manually at http://127.0.0.1:${SATDRESS_PORT}"
      fi
    done
  fi

  # ── Final nginx reload ──
  echo "  Validating and reloading nginx (requires sudo)"
  sudo nginx -t >/dev/null 2>&1 || fail "nginx config invalid"
  sudo systemctl reload nginx
  ok "nginx reloaded"
}

# ── Shell aliases ─────────────────────────────────────────────────────────────
# Install mostro-logs as a permanent bash function so the user can check
# Mostro output from any directory without remembering the full docker command.

install_shell_commands() {
  local bashrc="${HOME}/.bashrc"
  local marker="# --- mostro-regtest-aliases ---"

  # Remove previous version if it exists, then append fresh
  if grep -qF "${marker}" "${bashrc}" 2>/dev/null; then
    sed -i "/${marker}/,/${marker}/d" "${bashrc}"
  fi

  cat >> "${bashrc}" <<EOF
${marker}
mostro-logs() { docker compose -f "${BASE_DIR}/docker-compose.yml" logs --tail 100 -f mostro; }
${marker}
EOF

  ok "mostro-logs command installed (run: source ~/.bashrc or open a new terminal)"
}

# ── Summary ───────────────────────────────────────────────────────────────────

show_summary() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  SETUP COMPLETE"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Seeds saved at:"
  echo "    ${BASE_DIR}/lnd1/data/seed.txt"
  echo "    ${BASE_DIR}/lnd2/data/seed.txt"
  echo "    ${BASE_DIR}/lnd3/data/seed.txt"
  echo
  echo "  RTL web UI:"
  if [[ -n "${RTL_DOMAIN}" ]]; then
    echo "    https://${RTL_DOMAIN}"
  else
    echo "    http://127.0.0.1:${RTL_PORT}"
    echo "    SSH tunnel: ssh -L ${RTL_PORT}:127.0.0.1:${RTL_PORT} user@your-vps"
  fi
  echo
  echo "  Mostro (P2P exchange on lnd1):"
  echo "    Relays: ${MOSTRO_RELAYS}"
  echo "    Public key (npub): ${MOSTRO_NPUB}"
  echo "    Public key (hex):  ${MOSTRO_HEX}"
  echo "    Private key: ${BASE_DIR}/mostro/nostr-private.txt"
  echo

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    echo "  Lightning Addresses:"
    IFS=',' read -ra summary_users <<< "${LNURL_USERNAMES}"
    for uname in "${summary_users[@]}"; do
      uname="$(echo "$uname" | xargs)"
      [[ -z "$uname" ]] && continue
      echo "    ${uname}@${LNURL_DOMAIN}"
      echo "      https://${LNURL_DOMAIN}/.well-known/lnurlp/${uname}"
    done
    echo
  fi

  echo "  Channel balances:"
  for node in "${NODES[@]}"; do
    echo "  ── ${node} ──"
    lncli "$node" listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'
  done

  echo
  echo "  Useful commands:"
  echo "    mostro-logs  Shows last 100 lines + follows in real time"
  echo "    lncli1:  docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd1_rpc]} <cmd>"
  echo "    lncli2:  docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd2_rpc]} <cmd>"
  echo "    lncli3:  docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd3_rpc]} <cmd>"
  echo "    logs:    cd ${BASE_DIR} && docker compose logs -f"
  echo
}

# ── Summary file ──────────────────────────────────────────────────────────────
# Write a plain-text summary of everything created during setup so the user
# can reference it later without scrolling through terminal output.

write_summary_file() {
  local f="${BASE_DIR}/summary.txt"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"

  cat > "$f" <<EOF
===============================================
  MOSTRO REGTEST — SETUP SUMMARY
  Generated: ${ts}
===============================================

SEEDS
  lnd1: ${BASE_DIR}/lnd1/data/seed.txt
  lnd2: ${BASE_DIR}/lnd2/data/seed.txt
  lnd3: ${BASE_DIR}/lnd3/data/seed.txt

RTL WEB UI
EOF

  if [[ -n "${RTL_DOMAIN}" ]]; then
    echo "  URL: https://${RTL_DOMAIN}" >> "$f"
  else
    echo "  URL: http://127.0.0.1:${RTL_PORT}" >> "$f"
    echo "  SSH tunnel: ssh -L ${RTL_PORT}:127.0.0.1:${RTL_PORT} user@your-vps" >> "$f"
  fi

  cat >> "$f" <<EOF

MOSTRO (P2P exchange on lnd1)
  Relays: ${MOSTRO_RELAYS}
  Private key: ${BASE_DIR}/mostro/nostr-private.txt
EOF

  if [[ -n "${MOSTRO_NPUB}" ]]; then
    echo "  Public key (npub): ${MOSTRO_NPUB}" >> "$f"
  fi
  if [[ -n "${MOSTRO_HEX}" ]]; then
    echo "  Public key (hex):  ${MOSTRO_HEX}" >> "$f"
  fi

  if [[ -n "${LNURL_DOMAIN}" ]]; then
    echo "" >> "$f"
    echo "LIGHTNING ADDRESSES" >> "$f"
    IFS=',' read -ra file_users <<< "${LNURL_USERNAMES}"
    for uname in "${file_users[@]}"; do
      uname="$(echo "$uname" | xargs)"
      [[ -z "$uname" ]] && continue
      echo "  ${uname}@${LNURL_DOMAIN}" >> "$f"
      echo "    https://${LNURL_DOMAIN}/.well-known/lnurlp/${uname}" >> "$f"
    done
  fi

  cat >> "$f" <<EOF

USEFUL COMMANDS
  mostro-logs                     Last 100 lines + follow
  docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd1_rpc]} <cmd>
  docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd2_rpc]} <cmd>
  docker exec lnd3 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd3_rpc]} <cmd>
  cd ${BASE_DIR} && docker compose logs -f
EOF

  chmod 600 "$f"
  ok "Summary written to ${f}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  step_preflight
  step_deps
  step_clean
  step_password
  step_configs_and_start
  step_wallets_and_unlock
  step_mostro
  step_fund_and_channel
  step_domains
  install_shell_commands
  write_summary_file
  show_summary
}

main "$@"
