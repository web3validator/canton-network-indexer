#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ─── Network config ───────────────────────────────────────────────────────────
declare -A NET_LIGHTHOUSE=(
  [mainnet]="https://lighthouse.cantonloop.com"
  [testnet]="https://lighthouse.testnet.cantonloop.com"
  [devnet]="https://lighthouse.devnet.cantonloop.com"
)
declare -A NET_PORT=(
  [mainnet]="3010"
  [testnet]="3011"
  [devnet]="3012"
)
declare -A NET_DB_PORT=(
  [mainnet]="5440"
  [testnet]="5441"
  [devnet]="5442"
)
declare -A NET_DB_NAME=(
  [mainnet]="canton_mainnet"
  [testnet]="canton_testnet"
  [devnet]="canton_devnet"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEXER_DIR="$(cd "$SCRIPT_DIR/../indexer" && pwd)"

# ─── Usage ────────────────────────────────────────────────────────────────────
usage() {
  echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  -h, --host HOST       Remote host (e.g. 107.155.103.210)"
  echo "  -u, --user USER       SSH user (default: ubuntu)"
  echo "  -n, --networks NETS   Comma-separated networks: mainnet,testnet,devnet (default: ask)"
  echo "  -r, --remote-dir DIR  Remote deploy dir (default: ~/canton-indexer)"
  echo "  --stop NETS           Stop indexers for given networks and exit"
  echo "  --status              Show status of deployed indexers and exit"
  echo "  --help                Show this help"
  echo ""
  echo "Examples:"
  echo "  $0 -h 107.155.103.210 -u sol -n mainnet,testnet,devnet"
  echo "  $0 -h 107.155.103.210 -u sol --status"
  echo "  $0 -h 107.155.103.210 -u sol --stop devnet"
  exit 0
}

# ─── Args ─────────────────────────────────────────────────────────────────────
SSH_HOST=""
SSH_USER="ubuntu"
NETWORKS=""
REMOTE_BASE="canton-indexer"
ACTION="deploy"
STOP_NETS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--host)      SSH_HOST="$2";    shift 2 ;;
    -u|--user)      SSH_USER="$2";    shift 2 ;;
    -n|--networks)  NETWORKS="$2";    shift 2 ;;
    -r|--remote-dir) REMOTE_BASE="$2"; shift 2 ;;
    --stop)         ACTION="stop";   STOP_NETS="$2"; shift 2 ;;
    --status)       ACTION="status"; shift ;;
    --help)         usage ;;
    *) error "Unknown option: $1"; usage ;;
  esac
done

# ─── SSH helper ───────────────────────────────────────────────────────────────
ssh_run() { ssh -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "$@"; }
ssh_run_q() { ssh -o StrictHostKeyChecking=no -q "$SSH_USER@$SSH_HOST" "$@" 2>/dev/null || true; }

# ─── Prompt for host if not set ───────────────────────────────────────────────
if [[ -z "$SSH_HOST" ]]; then
  echo -e "${BOLD}Canton Network Indexer — Multi-Network Deploy${NC}"
  echo ""
  read -rp "Remote host IP or domain: " SSH_HOST
  read -rp "SSH user [ubuntu]: " input_user
  SSH_USER="${input_user:-ubuntu}"
fi

# ─── Test SSH ─────────────────────────────────────────────────────────────────
header "Checking SSH connection"
if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$SSH_HOST" "echo ok" &>/dev/null; then
  error "Cannot connect to $SSH_USER@$SSH_HOST"
  echo "  Make sure your SSH key is authorized on the remote host."
  exit 1
fi
ok "Connected to $SSH_USER@$SSH_HOST"

# ─── STATUS action ────────────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  header "Indexer Status on $SSH_HOST"
  for net in mainnet testnet devnet; do
    dir="~/$REMOTE_BASE-$net"
    port="${NET_PORT[$net]}"
    exists=$(ssh_run_q "test -d $dir && echo yes || echo no")
    if [[ "$exists" != "yes" ]]; then
      echo -e "  ${YELLOW}$net${NC}: not deployed"
      continue
    fi
    status=$(ssh_run_q "cd $dir && docker compose ps --format '{{.Status}}' 2>/dev/null | head -1" || echo "unknown")
    health=$(ssh_run_q "curl -s http://127.0.0.1:$port/health 2>/dev/null" || echo "")
    if echo "$health" | grep -q '"status":"ok"'; then
      uptime=$(echo "$health" | grep -o '"uptime":[0-9.]*' | cut -d: -f2)
      uptime_h=$(echo "$uptime / 3600" | bc 2>/dev/null || echo "?")
      echo -e "  ${GREEN}$net${NC}: healthy  port=$port  uptime=${uptime_h}h  [$status]"
    else
      echo -e "  ${RED}$net${NC}: unhealthy  port=$port  [$status]"
    fi
  done
  echo ""
  exit 0
fi

# ─── STOP action ──────────────────────────────────────────────────────────────
if [[ "$ACTION" == "stop" ]]; then
  header "Stopping indexers: $STOP_NETS"
  IFS=',' read -ra nets <<< "$STOP_NETS"
  for net in "${nets[@]}"; do
    net="${net// /}"
    dir="~/$REMOTE_BASE-$net"
    exists=$(ssh_run_q "test -d $dir && echo yes || echo no")
    if [[ "$exists" != "yes" ]]; then
      warn "$net: not deployed, skipping"
      continue
    fi
    info "Stopping $net..."
    ssh_run "cd $dir && docker compose down" && ok "$net stopped"
  done
  exit 0
fi

# ─── DEPLOY: choose networks ──────────────────────────────────────────────────
header "Network Selection"

if [[ -z "$NETWORKS" ]]; then
  echo "Which networks to deploy? (space-separated, or 'all')"
  echo "  1) mainnet"
  echo "  2) testnet"
  echo "  3) devnet"
  echo "  4) all"
  echo ""
  read -rp "Choice [all]: " net_input
  net_input="${net_input:-all}"

  if [[ "$net_input" == "all" || "$net_input" == "4" ]]; then
    NETWORKS="mainnet,testnet,devnet"
  else
    NETWORKS=""
    for token in $net_input; do
      case $token in
        1|mainnet) NETWORKS="${NETWORKS:+$NETWORKS,}mainnet" ;;
        2|testnet) NETWORKS="${NETWORKS:+$NETWORKS,}testnet" ;;
        3|devnet)  NETWORKS="${NETWORKS:+$NETWORKS,}devnet"  ;;
      esac
    done
  fi
fi

IFS=',' read -ra DEPLOY_NETS <<< "$NETWORKS"
info "Will deploy: ${DEPLOY_NETS[*]}"

# ─── Check indexer source ─────────────────────────────────────────────────────
header "Preparing source"
if [[ ! -f "$INDEXER_DIR/Dockerfile" ]]; then
  error "Indexer source not found at $INDEXER_DIR"
  exit 1
fi
ok "Source: $INDEXER_DIR"

# ─── Check remote Docker ──────────────────────────────────────────────────────
header "Checking remote Docker"
if ! ssh_run "docker info &>/dev/null"; then
  error "Docker not available on remote host"
  exit 1
fi
ok "Docker OK"

# ─── Copy source once ─────────────────────────────────────────────────────────
header "Uploading indexer source"

TMP_ARCHIVE="/tmp/canton-indexer-src-$$.tar.gz"
tar czf "$TMP_ARCHIVE" \
  --exclude="$INDEXER_DIR/node_modules" \
  --exclude="$INDEXER_DIR/dist" \
  -C "$(dirname "$INDEXER_DIR")" \
  "$(basename "$INDEXER_DIR")"

scp -o StrictHostKeyChecking=no "$TMP_ARCHIVE" "$SSH_USER@$SSH_HOST:/tmp/canton-indexer-src.tar.gz"
rm -f "$TMP_ARCHIVE"
ok "Source uploaded"

# ─── Deploy each network ──────────────────────────────────────────────────────
for net in "${DEPLOY_NETS[@]}"; do
  net="${net// /}"
  header "Deploying: $net"

  port="${NET_PORT[$net]}"
  db_port="${NET_DB_PORT[$net]}"
  db_name="${NET_DB_NAME[$net]}"
  lighthouse="${NET_LIGHTHOUSE[$net]}"
  remote_dir="~/$REMOTE_BASE-$net"

  info "Port: $port  DB port: $db_port  DB: $db_name"
  info "Lighthouse: $lighthouse"

  # Generate random DB password
  db_pass=$(openssl rand -hex 16 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 32)

  ssh_run bash -s -- "$remote_dir" "$net" "$port" "$db_port" "$db_name" "$db_pass" "$lighthouse" << 'REMOTE'
set -euo pipefail
REMOTE_DIR="$1"; NET="$2"; PORT="$3"; DB_PORT="$4"; DB_NAME="$5"; DB_PASS="$6"; LIGHTHOUSE="$7"

# Expand ~
REMOTE_DIR="${REMOTE_DIR/#\~/$HOME}"

mkdir -p "$REMOTE_DIR"
tar xzf /tmp/canton-indexer-src.tar.gz -C "$REMOTE_DIR" --strip-components=1

# Write .env
cat > "$REMOTE_DIR/.env" << ENV
CANTON_NETWORK=$NET
LIGHTHOUSE_URL=$LIGHTHOUSE
PORT=3000
HOST=0.0.0.0
LOG_LEVEL=info
DB_NAME=$DB_NAME
DB_USER=canton
DB_PASSWORD=$DB_PASS
DATABASE_URL=postgres://canton:${DB_PASS}@postgres:5432/${DB_NAME}
POLL_STATS_SEC=60
POLL_VALIDATORS_SEC=300
POLL_REWARDS_SEC=900
POLL_GOVERNANCE_SEC=1800
POLL_SNAPSHOT_SEC=3600
VALIDATOR_API_ENABLED=false
SCAN_API_ENABLED=false
ENV

# Write docker-compose.yml with network-specific ports/names
cat > "$REMOTE_DIR/docker-compose.yml" << DC
version: '3.9'

services:
  postgres:
    image: postgres:16-alpine
    container_name: canton-${NET}-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: \${DB_NAME:-$DB_NAME}
      POSTGRES_USER: \${DB_USER:-canton}
      POSTGRES_PASSWORD: \${DB_PASSWORD:-$DB_PASS}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "127.0.0.1:${DB_PORT}:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U canton -d $DB_NAME"]
      interval: 5s
      timeout: 5s
      retries: 10

  indexer:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: canton-${NET}-indexer
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file: .env
    environment:
      DATABASE_URL: postgres://canton:${DB_PASS}@postgres:5432/${DB_NAME}
    ports:
      - "127.0.0.1:${PORT}:3000"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:3000/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s

volumes:
  postgres_data:
DC

echo "Files written to $REMOTE_DIR"
REMOTE

  info "Building and starting $net indexer..."
  ssh_run "cd ~/$REMOTE_BASE-$net && docker compose up -d --build 2>&1" | tail -20

  # Wait for healthy
  info "Waiting for $net to become healthy (up to 120s)..."
  deadline=$((SECONDS + 120))
  while [[ $SECONDS -lt $deadline ]]; do
    health=$(ssh_run_q "curl -s http://127.0.0.1:$port/health" || echo "")
    if echo "$health" | grep -q '"status":"ok"'; then
      ok "$net indexer healthy on port $port"
      echo -e "  Network:    $net"
      echo -e "  Lighthouse: $lighthouse"
      echo -e "  API port:   $port (localhost)"
      echo -e "  DB port:    $db_port (localhost)"
      break
    fi
    sleep 5
  done
  if ! echo "$health" | grep -q '"status":"ok"'; then
    warn "$net indexer not healthy yet — check logs:"
    echo "  ssh $SSH_USER@$SSH_HOST 'docker logs canton-${net}-indexer --tail 30'"
  fi
done

# ─── Cleanup tmp ──────────────────────────────────────────────────────────────
ssh_run_q "rm -f /tmp/canton-indexer-src.tar.gz"

# ─── Final status ─────────────────────────────────────────────────────────────
header "Deploy Complete"
echo -e "${BOLD}Deployed networks:${NC}"
for net in "${DEPLOY_NETS[@]}"; do
  net="${net// /}"
  port="${NET_PORT[$net]}"
  health=$(ssh_run_q "curl -s http://127.0.0.1:$port/health" || echo "")
  if echo "$health" | grep -q '"status":"ok"'; then
    echo -e "  ${GREEN}✓${NC} $net  →  http://127.0.0.1:$port"
  else
    echo -e "  ${RED}✗${NC} $net  →  http://127.0.0.1:$port  (check logs)"
  fi
done

echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  Status:  $0 -h $SSH_HOST -u $SSH_USER --status"
echo "  Stop:    $0 -h $SSH_HOST -u $SSH_USER --stop mainnet"
echo "  Logs:    ssh $SSH_USER@$SSH_HOST 'docker logs canton-mainnet-indexer -f'"
echo "  API:     ssh -L 3010:localhost:3010 $SSH_USER@$SSH_HOST -N  →  http://localhost:3010/docs"
echo ""
