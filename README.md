# Canton Network Indexer

Unified REST API for Canton Network — aggregates Lighthouse Explorer, SV Scan, and Validator APIs into a single queryable layer with historical persistence for rewards, prices, and uptime.

## Why

Canton doesn't expose a single endpoint with full network state. Data is scattered across multiple APIs, and the public Lighthouse API has no historical data beyond 24h. This indexer fills the gap.

| Feature | Lighthouse | Indexer |
|---------|-----------|---------|
| Price history | 24h only | Unlimited (persisted) |
| Reward history | Current only | Full history per party |
| Validator uptime | Not available | Snapshot-based tracking |
| Transfer filtering | None | By sender, receiver, date range |
| Network health score | Not available | Aggregated score |
| Rewards leaderboard | Not available | Top earners ranking |

## Quick Start

```bash
git clone https://github.com/web3validator/canton-network-indexer
cd canton-network-indexer
cp .env.example .env
# Edit .env — set CANTON_NETWORK=mainnet|testnet|devnet
docker compose up -d
```

API at `http://localhost:3000`  
Swagger UI at `http://localhost:3000/docs`

## Multi-Network Deploy

Use the included `deploy_indexer.sh` to deploy one or more networks on a remote server. Each network runs as an isolated Docker Compose project on its own port.

| Network | Default Port | DB Port |
|---------|-------------|---------|
| mainnet | 3010 | 5440 |
| testnet | 3011 | 5441 |
| devnet  | 3012 | 5442 |

```bash
# Interactive
bash deploy_indexer.sh

# Deploy all three networks
bash deploy_indexer.sh -h 1.2.3.4 -u ubuntu -n mainnet,testnet,devnet

# Check status
bash deploy_indexer.sh -h 1.2.3.4 -u ubuntu --status

# Stop a network
bash deploy_indexer.sh -h 1.2.3.4 -u ubuntu --stop devnet
```

After deploy, configure nginx to expose the APIs publicly — see `nginx-indexer.conf` for a ready-to-use config with mainnet at `/` and `/testnet/`, `/devnet/` paths.

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Health check + DB status |
| `GET /api/stats` | Latest network stats |
| `GET /api/stats/history` | Historical stats snapshots |
| `GET /api/validators` | All validators |
| `GET /api/validators/:id` | Validator by ID |
| `GET /api/validators/:id/uptime` | Uptime history |
| `GET /api/validators/:id/rewards/history` | Historical rewards |
| `GET /api/parties/:id/balance` | CC balance |
| `GET /api/parties/:id/rewards` | Rewards (+ daily/weekly aggregation) |
| `GET /api/parties/:id/reward-stats` | Aggregated reward stats |
| `GET /api/parties/:id/transfers` | Transfers (sent/received) |
| `GET /api/parties/:id/transactions` | Transactions |
| `GET /api/parties/:id/burns` | Burns |
| `GET /api/parties/:id/burn-stats` | Burn stats |
| `GET /api/parties/:id/pnl` | Profit/loss |
| `GET /api/rewards/leaderboard` | Top earners ranking |
| `GET /api/transactions` | Transactions (+ date range filter) |
| `GET /api/transactions/:updateId` | Transaction by update ID |
| `GET /api/transfers` | Transfers (+ sender/receiver filter) |
| `GET /api/rounds` | Consensus rounds |
| `GET /api/rounds/:number` | Round by number |
| `GET /api/governance` | Governance vote requests |
| `GET /api/governance/stats` | Governance stats |
| `GET /api/governance/:id` | Vote request by ID |
| `GET /api/prices/latest` | Latest CC price in USD |
| `GET /api/prices/history` | Extended price history |
| `GET /api/cns` | Canton Name Service records |
| `GET /api/cns/:domain` | CNS record by domain |
| `GET /api/featured-apps` | Featured applications |
| `GET /api/preapprovals` | Preapproval records |
| `GET /api/search?q=...` | Universal search |
| `GET /api/network/health` | Aggregated network health score |

All list endpoints support `?live=true` to bypass cache and fetch directly from Lighthouse.

## Configuration

See `.env.example` for all options.

```
CANTON_NETWORK=mainnet        # mainnet | testnet | devnet
PORT=3000
DATABASE_URL=postgres://...
POLL_STATS_SEC=60             # polling interval in seconds
VALIDATOR_API_ENABLED=false   # enable for balance/party queries
SCAN_API_ENABLED=false        # enable if IP is whitelisted by Canton Foundation
```

**SV Scan API:** Contact Canton Foundation to get your server IP whitelisted. Once whitelisted, set `SCAN_API_ENABLED=true` and `SCAN_API_URL=https://scan.sv-1.global.canton.network.digitalasset.com` for access to full ledger data.

## Networks

| Network | Lighthouse URL |
|---------|---------------|
| MainNet | `https://lighthouse.cantonloop.com` |
| TestNet | `https://lighthouse.testnet.cantonloop.com` |
| DevNet  | `https://lighthouse.devnet.cantonloop.com` |

## Development

```bash
npm install
npm run dev        # ts-node with hot reload
npm run build      # compile to dist/
npm start          # run compiled
npm run typecheck  # type check without building
```

## Live Instance

| Network | URL |
|---------|-----|
| MainNet | `https://canton-indexer.web34ever.com` |
| TestNet | `https://canton-indexer.web34ever.com/testnet/` |
| DevNet  | `https://canton-indexer.web34ever.com/devnet/` |

## License

MIT