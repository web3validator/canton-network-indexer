import { Pool } from "pg";
import { config } from "../config.js";

let validatorPool: Pool | null = null;

if (config.validatorDb.connectionString) {
  validatorPool = new Pool({
    connectionString: config.validatorDb.connectionString,
    max: 3,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
  });

  validatorPool.on("error", (err) => {
    console.error("[validator-node] pool error", err.message);
  });
}

export interface NodeStatus {
  lag_seconds: number;
  last_ingested_at: string;
  is_healthy: boolean;
  validator_name: string | null;
  validator_party: string | null;
}

async function getValidatorName(
  pool: Pool,
): Promise<{ name: string | null; party: string | null }> {
  try {
    const result = await pool.query<{ descriptor: Record<string, unknown> }>(
      `SELECT descriptor FROM validator.store_descriptors
       WHERE descriptor::text LIKE '%DbValidatorStore%'
       LIMIT 1`,
    );
    const row = result.rows[0];
    if (!row) return { name: null, party: null };
    const party = (row.descriptor["party"] as string) ?? null;
    const name = party ? (party.split("::")[0] ?? null) : null;
    return { name, party };
  } catch {
    return { name: null, party: null };
  }
}

export async function getNodeStatus(): Promise<NodeStatus | null> {
  if (!validatorPool) return null;

  try {
    const [lagResult, { name, party }] = await Promise.all([
      validatorPool.query<{ lag_seconds: number; last_ingested_at: string }>(
        `SELECT
          EXTRACT(EPOCH FROM (NOW() - MAX(ingested_at)))::int AS lag_seconds,
          MAX(ingested_at) AS last_ingested_at
         FROM validator.update_history_transactions`,
      ),
      getValidatorName(validatorPool),
    ]);

    const row = lagResult.rows[0];
    if (!row || row.last_ingested_at == null) return null;

    return {
      lag_seconds: row.lag_seconds,
      last_ingested_at: new Date(row.last_ingested_at).toISOString(),
      is_healthy: row.lag_seconds < 1200,
      validator_name: name,
      validator_party: party,
    };
  } catch (err) {
    console.error("[validator-node] query failed:", (err as Error).message);
    return null;
  }
}

export const validatorNodeEnabled = validatorPool !== null;
