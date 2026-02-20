#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  lnd-setup.sh — Lightning Network (2 regtest nodes)
#
#  Uses network_mode: host to avoid Docker firewall issues.
#  Both nodes run on the host with different ports.
#
#  Steps:
#    1. Dependencies
#    2. Clean LND environment (bitcoind is NOT touched)
#    3. Ask wallet password
#    4. Write configs without auto-unlock
#    5. Start containers
#    6. Create wallets via REST API
#    7. Enable auto-unlock + restart
#    8. Fund wallets from miner
#    9. Open 5 BTC channel + rebalance 2.5/2.5
###############################################################################

# ── Paths and constants ─────────────────────────────────────────────────────
BASE_DIR="${HOME}/BTC/lnd"
LND_IMAGE="lightninglabs/lnd:v0.20.1-beta"

BITCOIND_HOST="127.0.0.1"
BITCOIND_RPC_PORT="18443"
BITCOIND_RPC_USER="bracr10"
BITCOIND_RPC_PASS="brian"
BITCOIND_NET="-regtest"
MINER_WALLET="miner"

ZMQ_BLOCK="tcp://${BITCOIND_HOST}:28332"
ZMQ_TX="tcp://${BITCOIND_HOST}:28333"

# Ports (host network — each node uses different ports)
LND1_LISTEN=9735
LND1_RPC=10009
LND1_REST=8080

LND2_LISTEN=9736
LND2_RPC=10010
LND2_REST=8081

FUND_LND1_BTC=8
FUND_LND2_BTC=3
CHANNEL_SATS=500000000    # 5 BTC
REBALANCE_SATS=250000000  # 2.5 BTC

WALLET_PASS=""

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo -e "\n\033[1;34m[$1]\033[0m $2"; }
ok()   { echo -e "  \033[1;32m✔\033[0m $1"; }
fail() { echo -e "  \033[1;31m✘\033[0m $1"; exit 1; }

lncli1() { docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${LND1_RPC} "$@" 2>/dev/null | tr -d '\r'; }
lncli2() { docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${LND2_RPC} "$@" 2>/dev/null | tr -d '\r'; }

bcli() { bitcoin-cli ${BITCOIND_NET} "$@"; }

mine_blocks() {
  local addr
  addr="$(bcli -rpcwallet="${MINER_WALLET}" getnewaddress)"
  bcli -rpcwallet="${MINER_WALLET}" generatetoaddress "$1" "$addr" >/dev/null
}

wait_ready() {
  local node="$1" rpc_port="$2" i=0
  echo "  Waiting for ${node}..."
  while [ $i -lt 120 ]; do
    if docker exec "$node" lncli --network=regtest --rpcserver=127.0.0.1:${rpc_port} getinfo >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  return 1
}

wait_wallet_unlocker() {
  local port="$1" i=0
  while [ $i -lt 60 ]; do
    local resp
    resp="$(curl -sk "https://127.0.0.1:${port}/v1/genseed" 2>/dev/null)" || true
    if echo "$resp" | jq -e '.cipher_seed_mnemonic' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  return 1
}

write_lnd_conf() {
  local node="$1" listen="$2" rpc="$3" rest="$4"
  local extra="${5:-}"
  cat > "${BASE_DIR}/${node}/lnd.conf" <<EOF
[Application Options]
alias=${node}
debuglevel=info
listen=0.0.0.0:${listen}
rpclisten=0.0.0.0:${rpc}
restlisten=0.0.0.0:${rest}
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

###############################################################################
#  STEP 1 — Dependencies
###############################################################################
step_deps() {
  log "1/9" "Installing dependencies"
  sudo apt-get update -qq
  sudo apt-get install -y -qq jq curl >/dev/null
  ok "jq and curl ready"
}

###############################################################################
#  STEP 2 — Clean (LND only, bitcoind untouched)
###############################################################################
step_clean() {
  log "2/9" "Cleaning LND environment (bitcoind NOT touched)"
  mkdir -p "${BASE_DIR}"
  cd "${BASE_DIR}"

  docker compose down -v --remove-orphans 2>/dev/null || true

  for node in lnd1 lnd2; do
    if [ -d "${node}" ]; then
      docker run --rm -v "${BASE_DIR}/${node}:/cleanup" alpine rm -rf /cleanup/data /cleanup/lnd.conf 2>/dev/null || true
      rm -rf "${node}" 2>/dev/null || true
    fi
  done
  rm -f docker-compose.yml 2>/dev/null || true

  mkdir -p lnd1/data lnd2/data
  ok "Directories clean"
}

###############################################################################
#  STEP 3 — Ask wallet password
###############################################################################
step_password() {
  log "3/9" "Wallet password for LND"
  echo
  read -s -p "  Enter password (min 8 chars): " WALLET_PASS
  echo
  read -s -p "  Confirm password: " pass_confirm
  echo

  if [ "$WALLET_PASS" != "$pass_confirm" ]; then
    fail "Passwords do not match"
  fi
  if [ ${#WALLET_PASS} -lt 8 ]; then
    fail "Minimum 8 characters"
  fi
  ok "Password accepted"
}

###############################################################################
#  STEP 4 — Configs without auto-unlock
###############################################################################
step_configs_initial() {
  log "4/9" "Writing initial configs (no auto-unlock)"
  cd "${BASE_DIR}"

  write_lnd_conf lnd1 "${LND1_LISTEN}" "${LND1_RPC}" "${LND1_REST}"
  write_lnd_conf lnd2 "${LND2_LISTEN}" "${LND2_RPC}" "${LND2_REST}"
  ok "lnd1/lnd.conf and lnd2/lnd.conf"

  cat > docker-compose.yml <<EOF
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
  ok "docker-compose.yml (network_mode: host)"
}

###############################################################################
#  STEP 5 — Start containers
###############################################################################
step_start() {
  log "5/9" "Starting containers"
  cd "${BASE_DIR}"
  docker compose up -d
  sleep 3
  ok "lnd1 and lnd2 running"
}

###############################################################################
#  STEP 6 — Create wallets via REST API
###############################################################################
create_wallet_rest() {
  local node="$1" rest_port="$2"
  local data_dir="${BASE_DIR}/${node}/data"

  echo "  Waiting for WalletUnlocker on ${node}..."
  wait_wallet_unlocker "$rest_port" || fail "${node} WalletUnlocker not responding"

  local seed_response
  seed_response="$(curl -sk "https://127.0.0.1:${rest_port}/v1/genseed")"
  local mnemonic
  mnemonic="$(echo "$seed_response" | jq -c '.cipher_seed_mnemonic')"

  if [ "$mnemonic" = "null" ] || [ -z "$mnemonic" ]; then
    fail "${node}: could not generate seed — $(echo "$seed_response")"
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
    fail "${node}: error creating wallet — $(echo "$init_response")"
  fi
}

step_wallets() {
  log "6/9" "Creating wallets via REST API"
  create_wallet_rest lnd1 "${LND1_REST}"
  create_wallet_rest lnd2 "${LND2_REST}"
}

###############################################################################
#  STEP 7 — Enable auto-unlock + restart
###############################################################################
step_enable_autounlock() {
  log "7/9" "Enabling auto-unlock and restarting"
  cd "${BASE_DIR}"

  for node in lnd1 lnd2; do
    echo -n "${WALLET_PASS}" > "${node}/data/wallet-password.txt"
    chmod 600 "${node}/data/wallet-password.txt"
  done

  write_lnd_conf lnd1 "${LND1_LISTEN}" "${LND1_RPC}" "${LND1_REST}" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"
  write_lnd_conf lnd2 "${LND2_LISTEN}" "${LND2_RPC}" "${LND2_REST}" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"

  docker compose restart
  sleep 5

  wait_ready lnd1 "${LND1_RPC}" || fail "lnd1 not responding"
  wait_ready lnd2 "${LND2_RPC}" || fail "lnd2 not responding"
  ok "Both nodes unlocked and ready"
}

###############################################################################
#  STEP 8 — Fund wallets from miner
###############################################################################
step_fund() {
  log "8/9" "Funding wallets from miner"

  if ! bcli listwallets | jq -e ".[] | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
    if bcli listwalletdir | jq -e ".wallets[].name | select(.==\"${MINER_WALLET}\")" >/dev/null 2>&1; then
      bcli loadwallet "${MINER_WALLET}" >/dev/null
    else
      bcli createwallet "${MINER_WALLET}" >/dev/null
    fi
  fi

  local addr1 addr2
  addr1="$(lncli1 newaddress p2wkh | jq -r '.address')"
  addr2="$(lncli2 newaddress p2wkh | jq -r '.address')"

  bcli -rpcwallet="${MINER_WALLET}" sendtoaddress "$addr1" "$FUND_LND1_BTC" >/dev/null
  bcli -rpcwallet="${MINER_WALLET}" sendtoaddress "$addr2" "$FUND_LND2_BTC" >/dev/null

  mine_blocks 6
  sleep 3

  ok "lnd1 received ${FUND_LND1_BTC} BTC, lnd2 received ${FUND_LND2_BTC} BTC"
}

###############################################################################
#  STEP 9 — Open 5 BTC channel + rebalance 2.5/2.5
###############################################################################
step_channel() {
  log "9/9" "Opening 5 BTC channel and rebalancing"

  local pub2
  pub2="$(lncli2 getinfo | jq -r '.identity_pubkey')"

  # Host network: connect via 127.0.0.1 with lnd2 port
  lncli1 connect "${pub2}@127.0.0.1:${LND2_LISTEN}" >/dev/null 2>&1 || true
  sleep 2

  lncli1 openchannel --node_key="${pub2}" --local_amt="${CHANNEL_SATS}" >/dev/null
  ok "Channel opened (pending confirmation)"

  mine_blocks 6
  sleep 5

  local invoice
  invoice="$(lncli2 addinvoice --amt="${REBALANCE_SATS}" --memo="rebalance" | jq -r '.payment_request')"
  lncli1 payinvoice --force "${invoice}" >/dev/null
  ok "Channel balanced ~2.5 BTC each side"
}

###############################################################################
#  Summary
###############################################################################
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
  echo "  ── lnd1 ──"
  lncli1 listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'
  echo "  ── lnd2 ──"
  lncli2 listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'

  echo
  echo "  Useful commands:"
  echo "    lncli1:  docker exec lnd1 lncli --network=regtest --rpcserver=127.0.0.1:${LND1_RPC} <cmd>"
  echo "    lncli2:  docker exec lnd2 lncli --network=regtest --rpcserver=127.0.0.1:${LND2_RPC} <cmd>"
  echo "    logs:    cd ${BASE_DIR} && docker compose logs -f"
  echo
}

###############################################################################
#  Main
###############################################################################
main() {
  step_deps
  step_clean
  step_password
  step_configs_initial
  step_start
  step_wallets
  step_enable_autounlock
  step_fund
  step_channel
  show_summary
}

main "$@"
