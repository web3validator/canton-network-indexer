# Canton Network Indexer

A unified REST API for Canton Network — aggregates Lighthouse and SV Scan APIs into a single queryable layer with historical persistence.

## Why

Canton doesn't expose a single endpoint with full network state. Data is scattered across multiple APIs, and the public Lighthouse API has no historical data beyond 24h. This indexer fills the gap.

| Feature | Lighthouse | This Indexer |
|---------|-----------|--------------|
| Price history | 24h only | Unlimited (persisted) |
| Reward history | Current only | Full history per party |
| Validator uptime | Not available | Snapshot-based tracking |
| Transfer filtering | None | By sender, receiver, date range |
| Full ledger stream | Not available | Via SV Scan (if whitelisted) |
| Network health score | Not available | Aggregated score |
| Rewards leaderboard | Not available | Top earners ranking |

## Quick Start

```bash
git clone https://github.com/web3validator/canton-network-indexer
cd canton-network-indexer
cp .env.example .env
# Edit .env — set CANTON_NETWORK and DATABASE_URL
docker compose up -d
```

API: `http://localhost:3000`  
Swagger UI: `http://localhost:3000/docs`

## Multi-Network Deploy

Use `deploy_indexer.sh` to deploy one or more networks locally or on a remote server. Each network runs as an isolated Docker Compose project on its own port.

| Network | Default Port | DB Port |
|---------|-------------|---------|
| mainnet | 3010 | 5440 |
| testnet | 3011 | 5441 |
| devnet  | 3012 | 5442 |

```bash
# Interactive local deploy
bash deploy_indexer.sh

# Deploy specific network
bash deploy_indexer.sh -n mainnet

# Deploy all three networks
bash deploy_indexer.sh -n mainnet,testnet,devnet

# Deploy on a remote server
bash deploy_indexer.sh --remote 1.2.3.4 --user ubuntu -n mainnet

# Check status
bash deploy_indexer.sh --status

# Stop a network
bash deploy_indexer.sh --stop devnet
```

The script will ask which data source to use:
- **Lighthouse only** — no whitelist needed, works everywhere (default)
- **SV Scan only** — requires IP whitelist
- **Both** — SV Scan primary, Lighthouse as fallback

When SV Scan is selected, the script automatically probes all known SV nodes for the chosen network and picks the first reachable one. If none respond, it falls back to Lighthouse automatically.

## Data Sources

### Lighthouse (default)

Public API, no authentication required.

| Network | URL |
|---------|-----|
| MainNet | `https://lighthouse.cantonloop.com` |
| TestNet | `https://lighthouse.testnet.cantonloop.com` |
| DevNet  | `https://lighthouse.devnet.cantonloop.com` |

### SV Scan (optional)

Full ledger event stream via `POST /api/scan/v2/updates`. Requires your server IP to be whitelisted by Canton Foundation — contact `pedro@canton.foundation` to request access.

Once whitelisted, set in `.env`:
```
SCAN_API_ENABLED=true
SCAN_API_URL=https://scan.sv-1.global.canton.network.digitalasset.com
```

When active, the indexer polls ledger updates every 30s and stores them in `ledger_updates` and `scan_rewards` tables.

## API Endpoints

### Core

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check — DB, Lighthouse reachability, SV Scan status |
| `GET /docs` | Swagger UI |

### Stats & Prices

| Endpoint | Description |
|----------|-------------|
| `GET /api/stats` | Latest network stats (validators, rounds, CC price) |
| `GET /api/stats/history` | Historical stats snapshots |
| `GET /api/prices/latest` | Latest CC price in USD |
| `GET /api/prices/history` | Full price history |

### Validators

| Endpoint | Description |
|----------|-------------|
| `GET /api/validators` | All validators with status |
| `GET /api/validators/:id` | Validator by ID |
| `GET /api/validators/:id/uptime` | Uptime history snapshots |
| `GET /api/validators/:id/rewards/history` | Historical rewards |

### Parties

| Endpoint | Description |
|----------|-------------|
| `GET /api/parties/:id/balance` | CC balance (live from Lighthouse) |
| `GET /api/parties/:id/rewards` | Rewards with daily/weekly aggregation |
| `GET /api/parties/:id/reward-stats` | Aggregated reward stats |
| `GET /api/parties/:id/transfers` | Sent and received transfers |
| `GET /api/parties/:id/transactions` | Transactions |
| `GET /api/parties/:id/pnl` | Profit/loss |
| `GET /api/parties/:id/burns` | Burns |
| `GET /api/parties/:id/burn-stats` | Burn stats |
| `GET /api/rewards/leaderboard` | Top earners ranking |

### Transactions & Transfers

| Endpoint | Description |
|----------|-------------|
| `GET /api/transactions` | All transactions (supports date range filter) |
| `GET /api/transactions/:updateId` | Transaction by update ID |
| `GET /api/transfers` | All transfers (supports sender/receiver filter) |

### Rounds & Governance

| Endpoint | Description |
|----------|-------------|
| `GET /api/rounds` | Consensus rounds |
| `GET /api/rounds/:number` | Round by number |
| `GET /api/governance` | Governance vote requests |
| `GET /api/governance/stats` | Governance stats snapshot |
| `GET /api/governance/:id` | Vote request by ID |

### Misc

| Endpoint | Description |
|----------|-------------|
| `GET /api/cns` | Canton Name Service records |
| `GET /api/cns/:domain` | CNS record by domain |
| `GET /api/featured-apps` | Featured applications |
| `GET /api/preapprovals` | Preapproval records |
| `GET /api/search?q=...` | Universal search across validators, parties, transactions |
| `GET /api/network/health` | Aggregated network health score |

### `/health` response example

```json
{
  "status": "ok",
  "network": "mainnet",
  "db": true,
  "lighthouse": true,
  "lighthouse_last_ok": "2026-03-05T00:07:00.000Z",
  "scan": true,
  "scan_last_ok": "2026-03-05T00:07:31.000Z",
  "uptime": 3600.5
}
```

`scan` field is only present when `SCAN_API_ENABLED=true`.

## Configuration

See `.env.example` for all options.

```env
CANTON_NETWORK=mainnet          # mainnet | testnet | devnet
PORT=3000
HOST=0.0.0.0
LOG_LEVEL=info

# Database
DB_NAME=canton_mainnet
DB_USER=canton
DB_PASSWORD=secret
DATABASE_URL=postgres://canton:secret@postgres:5432/canton_mainnet

# Polling intervals (seconds)
POLL_STATS_SEC=60
POLL_VALIDATORS_SEC=300
POLL_REWARDS_SEC=900
POLL_GOVERNANCE_SEC=1800
POLL_SNAPSHOT_SEC=3600

# SV Scan (requires IP whitelist from Canton Foundation)
SCAN_API_ENABLED=false
SCAN_API_URL=

# Validator node lag monitoring (optional)
# Connect to the local splice-validator postgres to track ledger ingestion lag
VALIDATOR_DB_URL=postgres://cnadmin:password@splice-validator-postgres-splice-1:5432/validator
```

## Database Schema

Core tables populated from Lighthouse:

| Table | Contents |
|-------|----------|
| `validators` | All validators with `is_active`, `version`, `last_seen_at` |
| `validator_snapshots` | Uptime history |
| `transactions` | Full transaction history |
| `transfers` | Transfer history |
| `rewards` | Rewards per party and round |
| `rounds` | Consensus rounds |
| `stats_snapshots` | Network stats over time |
| `prices` | CC price history |
| `governance_votes` | Governance vote requests |
| `cns_records` | Canton Name Service |
| `featured_apps` | Featured apps |

Additional tables populated from SV Scan (`SCAN_API_ENABLED=true`):

| Table | Contents |
|-------|----------|
| `ledger_updates` | Full ledger event stream from `v2/updates` |
| `scan_rewards` | Reward events extracted from ledger stream |
| `scan_mining_rounds` | Open and issuing mining rounds |
| `indexer_state` | Cursor storage for incremental polling |

## Development

```bash
npm install
npm run dev        # hot reload via tsx
npm run build      # compile TypeScript to dist/
npm start          # run compiled
```

## Validator Node Monitoring

The indexer can monitor how far behind the local validator node is in processing the ledger. This powers the node lag alerts in the alert bot.

### Setup

1. Set `VALIDATOR_DB_URL` in `.env` pointing to the splice-validator postgres:

```env
VALIDATOR_DB_URL=postgres://cnadmin:password@splice-validator-postgres-splice-1:5432/validator
```

2. Connect the indexer container to the validator's Docker network:

```bash
docker network connect splice-validator_splice_validator <indexer-container-name>
```

Or declare it in `docker-compose.yml`:

```yaml
services:
  indexer:
    networks:
      - default
      - splice_validator

networks:
  splice_validator:
    external: true
    name: splice-validator_splice_validator
```

### Endpoint

```
GET /api/validator/node-status
```

Response:

```json
{
  "enabled": true,
  "lag_seconds": 45,
  "last_ingested_at": "2026-03-11T03:38:00.625Z",
  "is_healthy": true,
  "validator_name": "web34ever",
  "validator_party": "web34ever::1220256be83146060986872d129d6dc37ab66e9706903438b5c3a590f976c53b3802"
}
```

- `enabled: false` — `VALIDATOR_DB_URL` not set, feature disabled
- `lag_seconds` — seconds since last ledger transaction ingested
- `is_healthy` — `true` if lag < 1200s (20 min)

The alert bot polls this endpoint every 60 seconds and sends alerts when:
- lag ≥ 600s (10 min) → ⚠️ node slow
- lag ≥ 1200s (20 min) → 🔴 node offline
- lag recovers below 600s → 🟢 node recovered

## Live Instances

| Network | URL |
|---------|-----|
| MainNet | `https://mainnet-canton-indexer.web34ever.com` |
| TestNet | `https://testnet-canton-indexer.web34ever.com` |
| DevNet  | `https://devnet-canton-indexer.web34ever.com` |

## License

MIT