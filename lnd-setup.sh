#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  lnd-setup.sh — Lightning Network (2 regtest nodes)
#
#  Spins up 2 LND nodes on regtest using Docker (host networking),
#  creates wallets, funds them from bitcoind, opens a channel and balances it.
#
#  Configuration: copy .env.example to .env and fill in your values.
#  Run ./lnd-setup.sh --help for usage information.
###############################################################################

# ── Usage ─────────────────────────────────────────────────────────────────────

show_usage() {
  cat <<'USAGE'
Usage: ./lnd-setup.sh [--help]

Sets up 2 LND regtest nodes with Docker (host networking).

Steps:
  1. Verifies prerequisites (docker, bitcoind, bitcoin-cli)
  2. Installs dependencies (jq, curl)
  3. Cleans previous LND state (bitcoind is NOT touched)
  4. Prompts for a wallet password
  5. Writes LND configs, docker-compose.yml, and starts containers
  6. Creates wallets and enables auto-unlock
  7. Funds wallets and opens a balanced channel

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

BITCOIND_HOST="${BITCOIND_HOST:-127.0.0.1}"
BITCOIND_RPC_PORT="${BITCOIND_RPC_PORT:-18443}"
MINER_WALLET="${MINER_WALLET:-miner}"
LND_IMAGE="${LND_IMAGE:-lightninglabs/lnd:v0.20.1-beta}"
FUND_LND1_BTC="${FUND_LND1_BTC:-8}"
FUND_LND2_BTC="${FUND_LND2_BTC:-3}"
CHANNEL_SATS="${CHANNEL_SATS:-500000000}"
REBALANCE_SATS="${REBALANCE_SATS:-250000000}"

ZMQ_BLOCK="tcp://${BITCOIND_HOST}:28332"
ZMQ_TX="tcp://${BITCOIND_HOST}:28333"

NODES=(lnd1 lnd2)
declare -A PORTS=(
  [lnd1_listen]=9735  [lnd1_rpc]=10009  [lnd1_rest]=8080
  [lnd2_listen]=9736  [lnd2_rpc]=10010  [lnd2_rest]=8081
)
declare -A FUND_BTC=(
  [lnd1]="${FUND_LND1_BTC}"
  [lnd2]="${FUND_LND2_BTC}"
)

WALLET_PASS="${WALLET_PASS:-}"

# ── Helpers ───────────────────────────────────────────────────────────────────

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

write_lnd_conf() {
  local node="$1" extra="${2:-}"
  cat > "${BASE_DIR}/${node}/lnd.conf" <<EOF
[Application Options]
alias=${node}
debuglevel=info
listen=0.0.0.0:${PORTS[${node}_listen]}
rpclisten=0.0.0.0:${PORTS[${node}_rpc]}
restlisten=0.0.0.0:${PORTS[${node}_rest]}
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

create_wallet_rest() {
  local node="$1"
  local rest_port="${PORTS[${node}_rest]}"
  local data_dir="${BASE_DIR}/${node}/data"

  echo "  Waiting for WalletUnlocker on ${node}..."
  wait_wallet_unlocker "$rest_port" || fail "${node} WalletUnlocker not responding"

  local seed_response
  seed_response="$(curl -sk "https://127.0.0.1:${rest_port}/v1/genseed")"
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
  init_response="$(curl -sk -X POST "https://127.0.0.1:${rest_port}/v1/initwallet" \
    -d "{\"wallet_password\":\"${pass_b64}\",\"cipher_seed_mnemonic\":${mnemonic}}")"

  if echo "$init_response" | jq -e '.admin_macaroon' >/dev/null 2>&1; then
    ok "${node} wallet created — seed at ${node}/data/seed.txt"
  else
    fail "${node}: error creating wallet — ${init_response}"
  fi
}

# ── Steps ─────────────────────────────────────────────────────────────────────

###############################################################################
#  STEP 1 — Preflight checks
###############################################################################
step_preflight() {
  log "1/7" "Preflight checks"

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
###############################################################################
step_deps() {
  log "2/7" "Checking dependencies (jq, curl)"

  local missing=()
  for cmd in jq curl; do
    if command -v "$cmd" &>/dev/null; then
      ok "${cmd} already installed"
    else
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    echo "  Installing: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "${missing[*]} installed"
  fi
}

###############################################################################
#  STEP 3 — Clean LND environment (bitcoind untouched)
###############################################################################
step_clean() {
  log "3/7" "Cleaning LND environment (bitcoind NOT touched)"

  docker compose -f "${BASE_DIR}/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
  docker rm -f "${NODES[@]}" 2>/dev/null || true

  for node in "${NODES[@]}"; do
    if [[ -d "${BASE_DIR}/${node}" ]]; then
      docker run --rm -v "${BASE_DIR}/${node}:/cleanup" alpine \
        rm -rf /cleanup/data /cleanup/lnd.conf 2>/dev/null || true
      rm -rf "${BASE_DIR:?}/${node}" 2>/dev/null || true
    fi
  done
  rm -f "${BASE_DIR}/docker-compose.yml" 2>/dev/null || true

  for node in "${NODES[@]}"; do
    mkdir -p "${BASE_DIR}/${node}/data"
  done
  ok "Directories clean"
}

###############################################################################
#  STEP 4 — Ask wallet password
###############################################################################
step_password() {
  log "4/7" "Wallet password for LND"

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
#  STEP 5 — Write configs + start containers
###############################################################################
step_configs_and_start() {
  log "5/7" "Writing configs and starting containers"

  for node in "${NODES[@]}"; do
    write_lnd_conf "$node"
  done
  ok "LND configs written"

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
EOF
  ok "docker-compose.yml written"

  docker compose -f "${BASE_DIR}/docker-compose.yml" up -d
  sleep 3
  ok "lnd1 and lnd2 running"
}

###############################################################################
#  STEP 6 — Create wallets + enable auto-unlock + restart
###############################################################################
step_wallets_and_unlock() {
  log "6/7" "Creating wallets and enabling auto-unlock"

  for node in "${NODES[@]}"; do
    create_wallet_rest "$node"
  done

  for node in "${NODES[@]}"; do
    echo -n "${WALLET_PASS}" > "${BASE_DIR}/${node}/data/wallet-password.txt"
    chmod 600 "${BASE_DIR}/${node}/data/wallet-password.txt"
    write_lnd_conf "$node" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"
  done

  docker compose -f "${BASE_DIR}/docker-compose.yml" restart
  sleep 5

  for node in "${NODES[@]}"; do
    wait_ready "$node" || fail "${node} not responding after restart"
  done
  ok "Both nodes unlocked and ready"
}

###############################################################################
#  STEP 7 — Fund wallets + open channel + rebalance
###############################################################################
step_fund_and_channel() {
  log "7/7" "Funding wallets and opening channel"

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
  ok "lnd1 received ${FUND_BTC[lnd1]} BTC, lnd2 received ${FUND_BTC[lnd2]} BTC"

  local pub2
  pub2="$(lncli lnd2 getinfo | jq -r '.identity_pubkey')"
  lncli lnd1 connect "${pub2}@127.0.0.1:${PORTS[lnd2_listen]}" >/dev/null 2>&1 || true
  sleep 2

  lncli lnd1 openchannel --node_key="${pub2}" --local_amt="${CHANNEL_SATS}" >/dev/null
  ok "Channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5

  local invoice
  invoice="$(lncli lnd2 addinvoice --amt="${REBALANCE_SATS}" --memo="rebalance" | jq -r '.payment_request')"
  lncli lnd1 payinvoice --force "${invoice}" >/dev/null
  ok "Channel balanced ~2.5 BTC each side"
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
  echo

  echo "  Channel balances:"
  for node in "${NODES[@]}"; do
    echo "  ── ${node} ──"
    lncli "$node" listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'
  done

  echo
  echo "  Useful commands:"
  echo "    lncli1:  docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd1_rpc]} <cmd>"
  echo "    lncli2:  docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${PORTS[lnd2_rpc]} <cmd>"
  echo "    logs:    cd ${BASE_DIR} && docker compose logs -f"
  echo
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  step_preflight
  step_deps
  step_clean
  step_password
  step_configs_and_start
  step_wallets_and_unlock
  step_fund_and_channel
  show_summary
}

main "$@"
