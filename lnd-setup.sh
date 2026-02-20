#!/usr/bin/env bash
set -euo pipefail

###############################################################################
#  lnd-setup.sh — Lightning Network (2 nodos regtest)
#
#  Usa network_mode: host para evitar problemas de firewall Docker.
#  Ambos nodos corren en el host con puertos diferentes.
#
#  Orden:
#    1. Dependencias
#    2. Limpieza LND (bitcoind NO se toca)
#    3. Pedir contrasena
#    4. Configs SIN auto-unlock
#    5. Contenedores
#    6. Crear wallets via REST API
#    7. Agregar auto-unlock + restart
#    8. Fondeo desde miner
#    9. Canal 5 BTC + balance 2.5/2.5
###############################################################################

# ── Rutas y constantes ──────────────────────────────────────────────────────
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

# Puertos (host network — cada nodo usa puertos distintos)
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
  echo "  Esperando ${node}..."
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
#  PASO 1 — Dependencias
###############################################################################
step_deps() {
  log "1/9" "Instalando dependencias"
  sudo apt-get update -qq
  sudo apt-get install -y -qq jq curl >/dev/null
  ok "jq y curl listos"
}

###############################################################################
#  PASO 2 — Limpieza (solo LND, bitcoind intacto)
###############################################################################
step_clean() {
  log "2/9" "Limpiando entorno LND (bitcoind NO se toca)"
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
  ok "Directorios limpios"
}

###############################################################################
#  PASO 3 — Pedir contrasena
###############################################################################
step_password() {
  log "3/9" "Contrasena para wallets LND"
  echo
  read -s -p "  Ingresa contrasena (min 8 chars): " WALLET_PASS
  echo
  read -s -p "  Confirma contrasena: " pass_confirm
  echo

  if [ "$WALLET_PASS" != "$pass_confirm" ]; then
    fail "Las contrasenas no coinciden"
  fi
  if [ ${#WALLET_PASS} -lt 8 ]; then
    fail "Minimo 8 caracteres"
  fi
  ok "Contrasena aceptada"
}

###############################################################################
#  PASO 4 — Configs SIN auto-unlock
###############################################################################
step_configs_initial() {
  log "4/9" "Configuraciones iniciales (sin auto-unlock)"
  cd "${BASE_DIR}"

  write_lnd_conf lnd1 "${LND1_LISTEN}" "${LND1_RPC}" "${LND1_REST}"
  write_lnd_conf lnd2 "${LND2_LISTEN}" "${LND2_RPC}" "${LND2_REST}"
  ok "lnd1/lnd.conf y lnd2/lnd.conf"

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
#  PASO 5 — Contenedores
###############################################################################
step_start() {
  log "5/9" "Iniciando contenedores"
  cd "${BASE_DIR}"
  docker compose up -d
  sleep 3
  ok "lnd1 y lnd2 corriendo"
}

###############################################################################
#  PASO 6 — Crear wallets via REST API
###############################################################################
create_wallet_rest() {
  local node="$1" rest_port="$2"
  local data_dir="${BASE_DIR}/${node}/data"

  echo "  Esperando WalletUnlocker en ${node}..."
  wait_wallet_unlocker "$rest_port" || fail "${node} WalletUnlocker no responde"

  local seed_response
  seed_response="$(curl -sk "https://127.0.0.1:${rest_port}/v1/genseed")"
  local mnemonic
  mnemonic="$(echo "$seed_response" | jq -c '.cipher_seed_mnemonic')"

  if [ "$mnemonic" = "null" ] || [ -z "$mnemonic" ]; then
    fail "${node}: no se pudo generar seed — $(echo "$seed_response")"
  fi

  echo "$seed_response" | jq -r '.cipher_seed_mnemonic[]' > "${data_dir}/seed.txt"
  chmod 600 "${data_dir}/seed.txt"

  local pass_b64
  pass_b64="$(echo -n "$WALLET_PASS" | base64)"

  local init_response
  init_response="$(curl -sk -X POST "https://127.0.0.1:${rest_port}/v1/initwallet" \
    -d "{\"wallet_password\":\"${pass_b64}\",\"cipher_seed_mnemonic\":${mnemonic}}")"

  if echo "$init_response" | jq -e '.admin_macaroon' >/dev/null 2>&1; then
    ok "${node} wallet creada — seed en ${node}/data/seed.txt"
  else
    fail "${node}: error creando wallet — $(echo "$init_response")"
  fi
}

step_wallets() {
  log "6/9" "Creando wallets via REST API"
  create_wallet_rest lnd1 "${LND1_REST}"
  create_wallet_rest lnd2 "${LND2_REST}"
}

###############################################################################
#  PASO 7 — Agregar auto-unlock + restart
###############################################################################
step_enable_autounlock() {
  log "7/9" "Activando auto-unlock y reiniciando"
  cd "${BASE_DIR}"

  for node in lnd1 lnd2; do
    echo -n "${WALLET_PASS}" > "${node}/data/wallet-password.txt"
    chmod 600 "${node}/data/wallet-password.txt"
  done

  write_lnd_conf lnd1 "${LND1_LISTEN}" "${LND1_RPC}" "${LND1_REST}" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"
  write_lnd_conf lnd2 "${LND2_LISTEN}" "${LND2_RPC}" "${LND2_REST}" "wallet-unlock-password-file=/root/.lnd/wallet-password.txt"

  docker compose restart
  sleep 5

  wait_ready lnd1 "${LND1_RPC}" || fail "lnd1 no responde"
  wait_ready lnd2 "${LND2_RPC}" || fail "lnd2 no responde"
  ok "Ambos nodos desbloqueados y listos"
}

###############################################################################
#  PASO 8 — Fondear wallets desde miner
###############################################################################
step_fund() {
  log "8/9" "Fondeando wallets desde miner"

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

  ok "lnd1 recibio ${FUND_LND1_BTC} BTC, lnd2 recibio ${FUND_LND2_BTC} BTC"
}

###############################################################################
#  PASO 9 — Canal 5 BTC + equilibrar 2.5/2.5
###############################################################################
step_channel() {
  log "9/9" "Abriendo canal de 5 BTC y equilibrando"

  local pub2
  pub2="$(lncli2 getinfo | jq -r '.identity_pubkey')"

  # Con host network, conectar via 127.0.0.1 con el puerto de lnd2
  lncli1 connect "${pub2}@127.0.0.1:${LND2_LISTEN}" >/dev/null 2>&1 || true
  sleep 2

  lncli1 openchannel --node_key="${pub2}" --local_amt="${CHANNEL_SATS}" >/dev/null
  ok "Canal abierto (pendiente confirmacion)"

  mine_blocks 6
  sleep 5

  local invoice
  invoice="$(lncli2 addinvoice --amt="${REBALANCE_SATS}" --memo="rebalance" | jq -r '.payment_request')"
  lncli1 payinvoice --force "${invoice}" >/dev/null
  ok "Canal equilibrado ~2.5 BTC cada lado"
}

###############################################################################
#  Resumen final
###############################################################################
show_summary() {
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  SETUP COMPLETO"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo
  echo "  Seeds guardadas en:"
  echo "    ${BASE_DIR}/lnd1/data/seed.txt"
  echo "    ${BASE_DIR}/lnd2/data/seed.txt"
  echo

  echo "  Balances del canal:"
  echo "  ── lnd1 ──"
  lncli1 listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'
  echo "  ── lnd2 ──"
  lncli2 listchannels | jq '.channels[] | {capacity, local_balance, remote_balance}'

  echo
  echo "  Comandos utiles:"
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
