#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}\n"; }

# ─── Network config ───────────────────────────────────────────────────────────
declare -A NET_LIGHTHOUSE=(
  [mainnet]="https://lighthouse.cantonloop.com"
  [testnet]="https://lighthouse.testnet.cantonloop.com"
  [devnet]="https://lighthouse.devnet.cantonloop.com"
)
declare -A NET_SCAN_LIST=(
  [mainnet]="https://scan.sv-1.global.canton.network.digitalasset.com https://scan.sv-2.global.canton.network.digitalasset.com https://scan.sv-1.global.canton.network.sync.global https://scan.sv-1.global.canton.network.cumberland.io https://scan.sv-1.global.canton.network.c7.digital https://scan.sv-1.global.canton.network.fivenorth.io"
  [testnet]="https://scan.sv-1.test.global.canton.network.digitalasset.com https://scan.sv-2.test.global.canton.network.digitalasset.com https://scan.sv.test.global.canton.network.digitalasset.com https://scan.sv-1.test.global.canton.network.sync.global https://scan.sv-1.test.global.canton.network.cumberland.io"
  [devnet]="https://scan.sv-1.dev.global.canton.network.digitalasset.com https://scan.sv-2.dev.global.canton.network.digitalasset.com https://scan.sv.dev.global.canton.network.digitalasset.com https://scan.sv-1.dev.global.canton.network.sync.global https://scan.sv-1.dev.global.canton.network.cumberland.io"
)
# Resolved at deploy time per network — populated by find_scan_url()
declare -A NET_SCAN_RESOLVED=()
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

# ─── Args ─────────────────────────────────────────────────────────────────────
NETWORKS=""
ACTION="deploy"
STOP_NETS=""
REMOTE_MODE=false
SSH_HOST=""
SSH_USER="ubuntu"
BASE_DIR="$HOME/canton-indexer"
DOMAIN=""
NGINX_MODE="local"  # local | domain

usage() {
  echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
  echo ""
  echo "  By default deploys locally on this machine."
  echo ""
  echo "Options:"
  echo "  -n, --networks NETS     mainnet,testnet,devnet or 'all' (default: ask)"
  echo "  -d, --dir DIR           Base deploy dir (default: ~/canton-indexer)"
  echo "  --remote HOST           Deploy to remote server via SSH"
  echo "  --user USER             SSH user for remote deploy (default: ubuntu)"
  echo "  --stop NETS             Stop indexers and exit"
  echo "  --status                Show status and exit"
  echo "  --help                  Show this help"
  echo ""
  echo "Examples:"
  echo "  $0                                          # interactive local deploy"
  echo "  $0 -n mainnet                               # deploy mainnet locally"
  echo "  $0 -n mainnet,testnet,devnet                # deploy all locally"
  echo "  $0 --remote 1.2.3.4 --user ubuntu -n all   # deploy all on remote"
  echo "  $0 --status"
  echo "  $0 --stop devnet"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--networks)  NETWORKS="$2";   shift 2 ;;
    -d|--dir)       BASE_DIR="$2";   shift 2 ;;
    --remote)       REMOTE_MODE=true; SSH_HOST="$2"; shift 2 ;;
    --user)         SSH_USER="$2";   shift 2 ;;
    --stop)         ACTION="stop";   STOP_NETS="$2"; shift 2 ;;
    --status)       ACTION="status"; shift ;;
    --help)         usage ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; usage ;;
  esac
done

# ─── Exec helpers ─────────────────────────────────────────────────────────────
# run_cmd: runs locally or remotely depending on mode
run_cmd() {
  if $REMOTE_MODE; then
    ssh -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" "$@"
  else
    bash -c "$*"
  fi
}

run_cmd_q() {
  if $REMOTE_MODE; then
    ssh -o StrictHostKeyChecking=no -q "$SSH_USER@$SSH_HOST" "$@" 2>/dev/null || true
  else
    bash -c "$*" 2>/dev/null || true
  fi
}

run_cmd_health() {
  local port="$1"
  if $REMOTE_MODE; then
    ssh -o StrictHostKeyChecking=no -q "$SSH_USER@$SSH_HOST" "curl -s http://127.0.0.1:$port/health" 2>/dev/null || true
  else
    curl -s "http://127.0.0.1:$port/health" 2>/dev/null || true
  fi
}

# ─── Check connection ─────────────────────────────────────────────────────────
if $REMOTE_MODE; then
  header "Checking SSH connection"
  if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_USER@$SSH_HOST" "echo ok" &>/dev/null; then
    error "Cannot connect to $SSH_USER@$SSH_HOST — check SSH key authorization"
  fi
  ok "Connected to $SSH_USER@$SSH_HOST"
  DEPLOY_TARGET="$SSH_HOST"
else
  header "Local deploy"
  ok "Deploying on this machine"
  DEPLOY_TARGET="localhost"
fi

# ─── STATUS ───────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  header "Indexer Status — $DEPLOY_TARGET"
  for net in mainnet testnet devnet; do
    port="${NET_PORT[$net]}"
    dir="$BASE_DIR-$net"
    exists=$(run_cmd_q "test -d $dir && echo yes || echo no")
    if [[ "$exists" != "yes" ]]; then
      echo -e "  ${YELLOW}$net${NC}: not deployed"
      continue
    fi
    compose_status=$(run_cmd_q "cd $dir && docker compose ps --format '{{.Status}}' 2>/dev/null | head -1" || echo "unknown")
    health=$(run_cmd_health "$port")
    if echo "$health" | grep -q '"status":"ok"'; then
      uptime_s=$(echo "$health" | grep -o '"uptime":[0-9.]*' | cut -d: -f2 | cut -d. -f1)
      uptime_h=$(( ${uptime_s:-0} / 3600 ))
      echo -e "  ${GREEN}✓ $net${NC}  port=$port  uptime=${uptime_h}h  [$compose_status]"
    else
      echo -e "  ${RED}✗ $net${NC}  port=$port  [${compose_status:-not running}]"
    fi
  done
  echo ""
  exit 0
fi

# ─── STOP ─────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "stop" ]]; then
  header "Stopping: $STOP_NETS"
  IFS=',' read -ra nets <<< "$STOP_NETS"
  for net in "${nets[@]}"; do
    net="${net// /}"
    dir="$BASE_DIR-$net"
    exists=$(run_cmd_q "test -d $dir && echo yes || echo no")
    if [[ "$exists" != "yes" ]]; then
      warn "$net: not deployed, skipping"
      continue
    fi
    info "Stopping $net..."
    run_cmd "cd $dir && docker compose down" && ok "$net stopped"
  done
  exit 0
fi

# ─── Choose networks ──────────────────────────────────────────────────────────
header "Network Selection"

if [[ -z "$NETWORKS" ]]; then
  echo "Which networks to deploy?"
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

[[ -z "$NETWORKS" ]] && error "No networks selected"
IFS=',' read -ra DEPLOY_NETS <<< "$NETWORKS"
info "Will deploy: ${DEPLOY_NETS[*]}"

# ─── Validator node monitoring ────────────────────────────────────────────────
header "Validator Node Monitoring (optional)"
echo "If this server runs a splice-validator node, the indexer can monitor"
echo "ledger ingestion lag via its local postgres database."
echo ""
echo "To enable, provide the validator postgres connection string."
echo "Example: postgres://cnadmin:password@splice-validator-postgres-splice-1:5432/validator"
echo ""
read -rp "VALIDATOR_DB_URL (leave empty to skip): " VALIDATOR_DB_URL
VALIDATOR_NETWORK_NAME=""
if [[ -n "$VALIDATOR_DB_URL" ]]; then
  read -rp "Docker network name of the validator (default: splice-validator_splice_validator): " VALIDATOR_NETWORK_NAME
  VALIDATOR_NETWORK_NAME="${VALIDATOR_NETWORK_NAME:-splice-validator_splice_validator}"
  ok "Node monitoring enabled — will connect to network: $VALIDATOR_NETWORK_NAME"
else
  info "Node monitoring skipped"
fi

# ─── Data source mode ─────────────────────────────────────────────────────────
header "Data Source"
echo "Select data source:"
echo "  1) Lighthouse only   — no whitelist needed, works everywhere (default)"
echo "  2) SV Scan only      — requires IP whitelist from Canton Foundation"
echo "  3) Both              — SV Scan primary, Lighthouse as fallback"
echo ""
echo -e "  ${YELLOW}⚠ SV Scan requires your server IP to be whitelisted.${NC}"
echo "    Contact Pedro Neves <pedro@canton.foundation> to request access."
echo ""
read -rp "Choice [1]: " source_input
source_input="${source_input:-1}"

SCAN_API_ENABLED="false"
SOURCE_MODE="lighthouse"

case "$source_input" in
  2|scan)
    SCAN_API_ENABLED="true"
    SOURCE_MODE="scan"
    info "SV Scan mode — will probe available SVs per network"
    ;;
  3|both)
    SCAN_API_ENABLED="true"
    SOURCE_MODE="both"
    info "Hybrid mode: SV Scan primary + Lighthouse fallback"
    ;;
  *)
    info "Lighthouse only mode"
    ;;
esac

# ─── SV Scan probe ────────────────────────────────────────────────────────────
# For each network that needs SV Scan — find first reachable SV
find_scan_url() {
  local net="$1"
  local candidates="${NET_SCAN_LIST[$net]:-}"
  [[ -z "$candidates" ]] && return 1

  info "Probing SV Scan nodes for $net..."
  for url in $candidates; do
    printf "  checking %-70s " "$url"
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url/api/scan/version" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
      echo -e "${GREEN}OK${NC}"
      NET_SCAN_RESOLVED[$net]="$url"
      return 0
    else
      echo -e "${RED}${status}${NC}"
    fi
  done
  return 1
}

if [[ "$SCAN_API_ENABLED" == "true" ]]; then
  header "Probing SV Scan Availability"
  ALL_SCAN_OK=true
  for net in "${DEPLOY_NETS[@]}"; do
    net="${net// /}"
    if find_scan_url "$net"; then
      ok "$net → ${NET_SCAN_RESOLVED[$net]}"
    else
      warn "$net → no SV Scan node reachable (your IP may not be whitelisted)"
      if [[ "$SOURCE_MODE" == "scan" ]]; then
        warn "  Falling back to Lighthouse for $net"
        warn "  To get whitelisted contact: pedro@canton.foundation"
      else
        warn "  Will use Lighthouse for $net"
      fi
      NET_SCAN_RESOLVED[$net]=""
      ALL_SCAN_OK=false
    fi
  done

  if [[ "$ALL_SCAN_OK" == "false" && "$SOURCE_MODE" == "scan" ]]; then
    echo ""
    warn "Some networks have no SV Scan access. Those will use Lighthouse instead."
    echo -e "  ${YELLOW}To request IP whitelist: pedro@canton.foundation${NC}"
    echo ""
  fi
fi

# ─── Access mode ──────────────────────────────────────────────────────────────
header "Access Configuration"
echo "How will the API be accessed?"
echo "  1) Locally only (localhost ports — default)"
echo "  2) Public via domain (nginx + SSL)"
echo ""
read -rp "Choice [1]: " access_input
access_input="${access_input:-1}"

if [[ "$access_input" == "2" || "$access_input" == "domain" ]]; then
  NGINX_MODE="domain"
  read -rp "Domain (e.g. indexer.example.com): " DOMAIN
  [[ -z "$DOMAIN" ]] && error "Domain cannot be empty"
  info "Will configure nginx for: $DOMAIN"
  info "  mainnet → https://$DOMAIN/"
  [[ "${#DEPLOY_NETS[@]}" -gt 1 ]] && info "  testnet → https://$DOMAIN/testnet/"
  [[ "${#DEPLOY_NETS[@]}" -gt 2 ]] && info "  devnet  → https://$DOMAIN/devnet/"
else
  NGINX_MODE="local"
  info "Local mode — APIs will be available on localhost only"
fi

# ─── Check Docker ─────────────────────────────────────────────────────────────
header "Checking Docker"
run_cmd "docker info" &>/dev/null || error "Docker not available"
ok "Docker OK"

# ─── Upload source (remote only) ──────────────────────────────────────────────
if $REMOTE_MODE; then
  header "Uploading source"
  TMP_ARCHIVE="/tmp/canton-indexer-src-$$.tar.gz"
  tar czf "$TMP_ARCHIVE" \
    --exclude="$SCRIPT_DIR/node_modules" \
    --exclude="$SCRIPT_DIR/dist" \
    -C "$SCRIPT_DIR" .
  scp -o StrictHostKeyChecking=no "$TMP_ARCHIVE" "$SSH_USER@$SSH_HOST:/tmp/canton-indexer-src.tar.gz"
  rm -f "$TMP_ARCHIVE"
  ok "Source uploaded"
fi

# ─── Write config files ───────────────────────────────────────────────────────
write_env() {
  local dir="$1" net="$2" lighthouse="$3" db_name="$4" db_pass="$5"
  local scan_url="${NET_SCAN_RESOLVED[$net]:-}"
  local scan_enabled="$SCAN_API_ENABLED"
  [[ -z "$scan_url" ]] && scan_enabled="false"
  printf 'CANTON_NETWORK=%s\nLIGHTHOUSE_URL=%s\nPORT=3000\nHOST=0.0.0.0\nLOG_LEVEL=info\n' \
    "$net" "$lighthouse" > "$dir/.env"
  printf 'DB_NAME=%s\nDB_USER=canton\nDB_PASSWORD=%s\nDATABASE_URL=postgres://canton:%s@postgres:5432/%s\n' \
    "$db_name" "$db_pass" "$db_pass" "$db_name" >> "$dir/.env"
  printf 'POLL_STATS_SEC=60\nPOLL_VALIDATORS_SEC=300\nPOLL_REWARDS_SEC=900\n' >> "$dir/.env"
  printf 'POLL_GOVERNANCE_SEC=1800\nPOLL_SNAPSHOT_SEC=3600\n' >> "$dir/.env"
  printf 'VALIDATOR_API_ENABLED=false\nSCAN_API_ENABLED=%s\nSCAN_API_URL=%s\n' \
    "$scan_enabled" "$scan_url" >> "$dir/.env"
  if [[ -n "${VALIDATOR_DB_URL:-}" ]]; then
    printf 'VALIDATOR_DB_URL=%s\n' "$VALIDATOR_DB_URL" >> "$dir/.env"
  fi
}

write_compose() {
  local dir="$1" net="$2" port="$3" db_port="$4" db_name="$5" db_pass="$6"
  {
    printf '%s\n' \
      "version: '3.9'" \
      "services:" \
      "  postgres:" \
      "    image: postgres:16-alpine" \
      "    container_name: canton-${net}-postgres" \
      "    restart: unless-stopped" \
      "    environment:" \
      "      POSTGRES_DB: ${db_name}" \
      "      POSTGRES_USER: canton" \
      "      POSTGRES_PASSWORD: ${db_pass}" \
      "    volumes:" \
      "      - postgres_data:/var/lib/postgresql/data" \
      "    ports:" \
      "      - \"127.0.0.1:${db_port}:5432\"" \
      "    healthcheck:" \
      "      test: [\"CMD-SHELL\", \"pg_isready -U canton -d ${db_name}\"]" \
      "      interval: 5s" \
      "      timeout: 5s" \
      "      retries: 10" \
      "  indexer:" \
      "    build:" \
      "      context: ." \
      "      dockerfile: Dockerfile" \
      "    container_name: canton-${net}-indexer" \
      "    restart: unless-stopped" \
      "    depends_on:" \
      "      postgres:" \
      "        condition: service_healthy" \
      "    env_file: .env" \
      "    environment:" \
      "      DATABASE_URL: postgres://canton:${db_pass}@postgres:5432/${db_name}"
    if [[ -n "${VALIDATOR_DB_URL:-}" ]]; then
      printf '      VALIDATOR_DB_URL: %s\n' "$VALIDATOR_DB_URL"
    fi
    printf '%s\n' \
      "    ports:" \
      "      - \"127.0.0.1:${port}:3000\""
    if [[ -n "${VALIDATOR_NETWORK_NAME:-}" ]]; then
      printf '%s\n' \
        "    networks:" \
        "      - default" \
        "      - splice_validator"
    fi
    printf '%s\n' \
      "    healthcheck:" \
      "      test: [\"CMD-SHELL\", \"wget -qO- http://127.0.0.1:3000/health || exit 1\"]" \
      "      interval: 15s" \
      "      timeout: 5s" \
      "      retries: 5" \
      "      start_period: 60s" \
      "volumes:" \
      "  postgres_data:"
    if [[ -n "${VALIDATOR_NETWORK_NAME:-}" ]]; then
      printf '%s\n' \
        "networks:" \
        "  splice_validator:" \
        "    external: true" \
        "    name: ${VALIDATOR_NETWORK_NAME}"
    fi
  } > "$dir/docker-compose.yml"
}

# ─── Deploy each network ──────────────────────────────────────────────────────
for net in "${DEPLOY_NETS[@]}"; do
  net="${net// /}"
  header "Deploying: $net"

  port="${NET_PORT[$net]}"
  db_port="${NET_DB_PORT[$net]}"
  db_name="${NET_DB_NAME[$net]}"
  lighthouse="${NET_LIGHTHOUSE[$net]}"
  deploy_dir="$BASE_DIR-$net"

  info "Port: $port  |  DB port: $db_port  |  Lighthouse: $lighthouse"

  db_pass=$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' < /dev/urandom | head -c 32)

  # If already deployed — stop and remove volumes to avoid stale DB password
  if $REMOTE_MODE; then
    exists=$(run_cmd_q "test -d $deploy_dir && echo yes || echo no")
  else
    [[ -d "$deploy_dir" ]] && exists="yes" || exists="no"
  fi
  if [[ "$exists" == "yes" ]]; then
    info "$net already deployed — stopping and removing old volumes..."
    run_cmd "cd $deploy_dir && docker compose down -v 2>&1" | tail -5
  fi

  if $REMOTE_MODE; then
    # Write files locally to a tmp dir, scp them over
    TMP_DIR=$(mktemp -d)
    rsync -a --exclude='node_modules' --exclude='dist' "$SCRIPT_DIR/" "$TMP_DIR/"
    write_env "$TMP_DIR" "$net" "$lighthouse" "$db_name" "$db_pass"
    write_compose "$TMP_DIR" "$net" "$port" "$db_port" "$db_name" "$db_pass"
    TMP_ARCHIVE="/tmp/canton-indexer-${net}-$$.tar.gz"
    tar czf "$TMP_ARCHIVE" -C "$TMP_DIR" .
    rm -rf "$TMP_DIR"
    scp -o StrictHostKeyChecking=no "$TMP_ARCHIVE" "$SSH_USER@$SSH_HOST:/tmp/canton-indexer-${net}.tar.gz"
    rm -f "$TMP_ARCHIVE"
    ssh -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" \
      "mkdir -p $deploy_dir && tar xzf /tmp/canton-indexer-${net}.tar.gz -C $deploy_dir && rm -f /tmp/canton-indexer-${net}.tar.gz"
  else
    mkdir -p "$deploy_dir"
    rsync -a --exclude='node_modules' --exclude='dist' --exclude='*-mainnet' \
      --exclude='*-testnet' --exclude='*-devnet' "$SCRIPT_DIR/" "$deploy_dir/"
    write_env "$deploy_dir" "$net" "$lighthouse" "$db_name" "$db_pass"
    write_compose "$deploy_dir" "$net" "$port" "$db_port" "$db_name" "$db_pass"
  fi
  ok "Config written to $deploy_dir"

  info "Building and starting $net..."
  run_cmd "cd $deploy_dir && docker compose up -d --build 2>&1" | tail -15

  if [[ -n "${VALIDATOR_NETWORK_NAME:-}" ]]; then
    info "Connecting canton-${net}-indexer to validator network: $VALIDATOR_NETWORK_NAME"
    if $REMOTE_MODE; then
      ssh -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" \
        "docker network connect $VALIDATOR_NETWORK_NAME canton-${net}-indexer 2>/dev/null && echo connected || echo already connected" || true
    else
      docker network connect "$VALIDATOR_NETWORK_NAME" "canton-${net}-indexer" 2>/dev/null && \
        ok "Connected to $VALIDATOR_NETWORK_NAME" || info "Already connected to $VALIDATOR_NETWORK_NAME"
    fi
  fi

  info "Waiting for $net to become healthy (up to 120s)..."
  health=""
  deadline=$((SECONDS + 120))
  while [[ $SECONDS -lt $deadline ]]; do
    health=$(run_cmd_health "$port")
    if echo "$health" | grep -q '"status":"ok"'; then
      ok "$net is healthy"
      break
    fi
    sleep 5
  done

  if echo "$health" | grep -q '"status":"ok"'; then
    echo -e "  ${GREEN}✓${NC} API:  http://127.0.0.1:$port"
    echo -e "  ${GREEN}✓${NC} Docs: http://127.0.0.1:$port/docs"
  else
    warn "$net not healthy yet — check logs:"
    if $REMOTE_MODE; then
      echo "  ssh $SSH_USER@$SSH_HOST 'docker logs canton-${net}-indexer --tail 30'"
    else
      echo "  docker logs canton-${net}-indexer --tail 30"
    fi
  fi
done

# ─── Cleanup ──────────────────────────────────────────────────────────────────
$REMOTE_MODE && run_cmd_q "rm -f /tmp/canton-indexer-src.tar.gz"

# ─── Nginx setup ──────────────────────────────────────────────────────────────
if [[ "$NGINX_MODE" == "domain" ]]; then
  header "Configuring nginx for $DOMAIN"

  NGINX_CONF="/etc/nginx/sites-available/canton-indexer"

  # Build nginx config using printf
  {
    printf 'server {\n'
    printf '    listen 80;\n'
    printf '    server_name %s;\n\n' "$DOMAIN"
    printf '    # mainnet — default\n'
    printf '    location / {\n'
    printf '        proxy_pass http://127.0.0.1:%s;\n' "${NET_PORT[mainnet]}"
    printf '        proxy_http_version 1.1;\n'
    printf '        proxy_set_header Host $host;\n'
    printf '        proxy_set_header X-Real-IP $remote_addr;\n'
    printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
    printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
    printf '    }\n'

    # add /testnet/ block if testnet deployed
    if printf '%s\n' "${DEPLOY_NETS[@]}" | grep -q '^testnet$'; then
      printf '\n    location /testnet/ {\n'
      printf '        rewrite ^/testnet/(.*) /$1 break;\n'
      printf '        proxy_pass http://127.0.0.1:%s;\n' "${NET_PORT[testnet]}"
      printf '        proxy_http_version 1.1;\n'
      printf '        proxy_set_header Host $host;\n'
      printf '        proxy_set_header X-Real-IP $remote_addr;\n'
      printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
      printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
      printf '    }\n'
    fi

    # add /devnet/ block if devnet deployed
    if printf '%s\n' "${DEPLOY_NETS[@]}" | grep -q '^devnet$'; then
      printf '\n    location /devnet/ {\n'
      printf '        rewrite ^/devnet/(.*) /$1 break;\n'
      printf '        proxy_pass http://127.0.0.1:%s;\n' "${NET_PORT[devnet]}"
      printf '        proxy_http_version 1.1;\n'
      printf '        proxy_set_header Host $host;\n'
      printf '        proxy_set_header X-Real-IP $remote_addr;\n'
      printf '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n'
      printf '        proxy_set_header X-Forwarded-Proto $scheme;\n'
      printf '    }\n'
    fi

    printf '}\n'
  } > /tmp/canton-nginx.conf

  if command -v nginx &>/dev/null; then
    sudo cp /tmp/canton-nginx.conf "$NGINX_CONF"
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/canton-indexer 2>/dev/null || true
    if sudo nginx -t &>/dev/null; then
      if sudo systemctl is-active --quiet nginx 2>/dev/null; then
        sudo systemctl reload nginx
      else
        sudo systemctl start nginx
      fi
      ok "nginx configured and reloaded"
    else
      warn "nginx config test failed — check $NGINX_CONF"
    fi

    # SSL via certbot — auto-install if missing
    if ! command -v certbot &>/dev/null; then
      info "certbot not found — installing..."
      sudo apt-get install -y certbot python3-certbot-nginx -qq && ok "certbot installed" || \
        warn "certbot install failed — SSL skipped"
    fi
    if command -v certbot &>/dev/null; then
      sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email \
        && ok "SSL certificate obtained for $DOMAIN" \
        || warn "certbot failed — run manually: sudo certbot --nginx -d $DOMAIN"
    fi
  else
    warn "nginx not installed — config saved to /tmp/canton-nginx.conf"
    echo "  Install nginx and copy the config manually:"
    echo "  sudo apt install nginx -y"
    echo "  sudo cp /tmp/canton-nginx.conf /etc/nginx/sites-available/canton-indexer"
    echo "  sudo ln -s /etc/nginx/sites-available/canton-indexer /etc/nginx/sites-enabled/"
    echo "  sudo systemctl start nginx"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Deploy Complete"
for net in "${DEPLOY_NETS[@]}"; do
  net="${net// /}"
  port="${NET_PORT[$net]}"
  health=$(run_cmd_health "$port")
  if echo "$health" | grep -q '"status":"ok"'; then
    if [[ "$NGINX_MODE" == "domain" ]]; then
      if [[ "$net" == "mainnet" ]]; then
        echo -e "  ${GREEN}✓${NC} $net  →  https://$DOMAIN/"
      else
        echo -e "  ${GREEN}✓${NC} $net  →  https://$DOMAIN/$net/"
      fi
    else
      echo -e "  ${GREEN}✓${NC} $net  →  http://127.0.0.1:$port"
    fi
  else
    echo -e "  ${RED}✗${NC} $net  →  http://127.0.0.1:$port  (not healthy)"
  fi
done

echo ""
if $REMOTE_MODE; then
  echo -e "${BOLD}Useful commands:${NC}"
  echo "  Status: $0 --remote $SSH_HOST --user $SSH_USER --status"
  echo "  Stop:   $0 --remote $SSH_HOST --user $SSH_USER --stop mainnet"
  echo "  Logs:   ssh $SSH_USER@$SSH_HOST 'docker logs canton-mainnet-indexer -f'"
  echo "  Tunnel: ssh -L 3010:localhost:3010 $SSH_USER@$SSH_HOST -N"
else
  echo -e "${BOLD}Useful commands:${NC}"
  echo "  Status: $0 --status"
  echo "  Stop:   $0 --stop mainnet"
  echo "  Logs:   docker logs canton-mainnet-indexer -f"
  if [[ "$NGINX_MODE" == "domain" ]]; then
    echo "  API:    https://$DOMAIN  (mainnet)"
    printf '%s\n' "${DEPLOY_NETS[@]}" | grep -q '^testnet$' && echo "          https://$DOMAIN/testnet/"
    printf '%s\n' "${DEPLOY_NETS[@]}" | grep -q '^devnet$'  && echo "          https://$DOMAIN/devnet/"
  else
    echo "  API:    http://127.0.0.1:3010  (mainnet)"
    echo "          http://127.0.0.1:3011  (testnet)"
    echo "          http://127.0.0.1:3012  (devnet)"
  fi
fi
echo ""
