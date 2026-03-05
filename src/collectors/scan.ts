import { fetch } from "undici";
import { config } from "../config.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface ScanUpdate {
  update_id: string;
  migration_id: number;
  workflow_id?: string;
  record_time: string;
  synchronizer_id?: string;
  effective_at?: string;
  offset?: string;
  root_event_ids?: string[];
  events_by_id: Record<string, ScanEvent>;
}

export interface ScanCreatedEvent {
  event_type: "created_event";
  event_id: string;
  contract_id: string;
  template_id: string;
  package_name?: string;
  create_arguments?: Record<string, unknown>;
  created_at?: string;
  signatories?: string[];
  observers?: string[];
}

export interface ScanExercisedEvent {
  event_type: "exercised_event";
  event_id: string;
  contract_id: string;
  template_id: string;
  package_name?: string;
  choice: string;
  choice_argument?: Record<string, unknown>;
  exercise_result?: unknown;
  child_event_ids?: string[];
  consuming: boolean;
  acting_parties?: string[];
  interface_id?: string | null;
}

export type ScanEvent = ScanCreatedEvent | ScanExercisedEvent;

export interface ScanUpdatesResponse {
  transactions: ScanUpdate[];
}

export interface ScanCursor {
  after_migration_id: number;
  after_record_time: string;
}

export interface HoldingsSummaryEntry {
  party_id: string;
  total_unlocked_coin: string;
  total_locked_coin: string;
  total_coin_holdings: string;
  accumulated_holding_fees_unlocked: string;
  accumulated_holding_fees_locked: string;
  accumulated_holding_fees_total: string;
  total_available_coin: string;
}

export interface HoldingsSummaryResponse {
  record_time: string;
  migration_id: number;
  computed_as_of_round: number;
  summaries: HoldingsSummaryEntry[];
}

export interface MiningRound {
  contract_id?: string;
  round?: { number: string };
  amulet_price?: string;
  opens_at?: string;
  target_closes_at?: string;
  [key: string]: unknown;
}

export interface OpenAndIssuingMiningRoundsResponse {
  open_mining_rounds: MiningRound[];
  issuing_mining_rounds: MiningRound[];
}

type ScanResult<T> = { ok: true; data: T } | { ok: false; status: number; error: string };

// ── Template ID helpers ───────────────────────────────────────────────────────

// Reward coupon templates — used to detect reward events in updates stream
export const REWARD_TEMPLATES = [
  "Splice.Amulet.AppRewardCoupon",
  "Splice.Amulet.ValidatorRewardCoupon",
  "Splice.Amulet.SvRewardCoupon",
  "Splice.Amulet.ValidatorFaucetCoupon",
];

// Transfer template
export const TRANSFER_TEMPLATES = ["Splice.Amulet.Transfer", "Splice.AmuletRules.Transfer"];

// Amulet (coin holding) template
export const AMULET_TEMPLATES = ["Splice.Amulet.Amulet", "Splice.Amulet.LockedAmulet"];

export function templateShortName(templateId: string): string {
  // "package_hash:Module.Name:TemplateName" → "Module.Name:TemplateName"
  const parts = templateId.split(":");
  return parts.length >= 3 ? `${parts[1]}:${parts[2]}` : templateId;
}

export function matchesTemplate(templateId: string, patterns: string[]): boolean {
  const short = templateShortName(templateId);
  return patterns.some((p) => short.includes(p));
}

// ── ScanCollector ─────────────────────────────────────────────────────────────

class ScanCollector {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;

  // Reachability tracking — used by health endpoint
  public lastReachable: boolean = true;
  public lastReachableAt: Date | null = null;

  constructor() {
    this.baseUrl = config.scanApi.baseUrl;
    this.timeoutMs = config.lighthouse.timeoutMs; // reuse same timeout setting
  }

  get enabled(): boolean {
    return config.scanApi.enabled && this.baseUrl.length > 0;
  }

  // ── HTTP helpers ──────────────────────────────────────────────────────────

  private async get<T>(path: string): Promise<ScanResult<T>> {
    return this.request<T>("GET", path, undefined, 3);
  }

  private async post<T>(path: string, body: unknown, retries = 3): Promise<ScanResult<T>> {
    return this.request<T>("POST", path, body, retries);
  }

  private async request<T>(
    method: string,
    path: string,
    body: unknown,
    retries: number,
  ): Promise<ScanResult<T>> {
    const url = `${this.baseUrl}${path}`;
    let lastError = "";

    for (let attempt = 0; attempt < retries; attempt++) {
      if (attempt > 0) {
        await new Promise((r) => setTimeout(r, 1000 * attempt));
      }
      try {
        const res = await fetch(url, {
          method,
          signal: AbortSignal.timeout(this.timeoutMs),
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
          },
          body: body !== undefined ? JSON.stringify(body) : undefined,
        });

        if (!res.ok) {
          const text = await res.text().catch(() => "");
          lastError = text.slice(0, 300);
          // Don't retry 4xx
          if (res.status >= 400 && res.status < 500) {
            this.lastReachable = false;
            return { ok: false, status: res.status, error: lastError };
          }
          continue;
        }

        const data = (await res.json()) as T;
        this.lastReachable = true;
        this.lastReachableAt = new Date();
        return { ok: true, data };
      } catch (err) {
        lastError = err instanceof Error ? err.message : String(err);
      }
    }

    this.lastReachable = false;
    return { ok: false, status: 0, error: lastError };
  }

  // ── Version ───────────────────────────────────────────────────────────────

  async getVersion(): Promise<ScanResult<{ version: string; commit_ts?: string }>> {
    return this.get("/api/scan/version");
  }

  // ── DSO party ID ─────────────────────────────────────────────────────────

  async getDsoPartyId(): Promise<ScanResult<{ dso_party_id: string }>> {
    return this.get("/api/scan/v0/dso-party-id");
  }

  // ── Updates stream (v2) ───────────────────────────────────────────────────
  // Primary endpoint — full ledger event stream with cursor pagination
  // Pass cursor=null for oldest-first (from genesis)
  // Pass cursor with after_migration_id/after_record_time for newest-first

  async getUpdates(
    pageSize: number,
    cursor?: ScanCursor,
  ): Promise<ScanResult<ScanUpdatesResponse>> {
    const body: Record<string, unknown> = {
      page_size: pageSize,
      daml_value_encoding: "compact_json",
    };
    if (cursor) {
      body["after"] = cursor;
    }
    return this.post<ScanUpdatesResponse>("/api/scan/v2/updates", body);
  }

  // Convenience: get updates from the beginning (no cursor = oldest first)
  async getLatestUpdates(pageSize = 100): Promise<ScanResult<ScanUpdatesResponse>> {
    return this.getUpdates(pageSize);
  }

  // ── Holdings summary (balance) ────────────────────────────────────────────

  async getHoldingsSummary(
    partyIds: string[],
    migrationId?: number,
    recordTime?: string,
  ): Promise<ScanResult<HoldingsSummaryResponse>> {
    const body: Record<string, unknown> = { owner_party_ids: partyIds };
    if (migrationId !== undefined) body["migration_id"] = migrationId;
    if (recordTime) body["record_time"] = recordTime;
    return this.post<HoldingsSummaryResponse>("/api/scan/v0/holdings/summary", body);
  }

  // ── Mining rounds ─────────────────────────────────────────────────────────

  async getOpenAndIssuingMiningRounds(
    cachedOpenIds: string[] = [],
    cachedIssuingIds: string[] = [],
  ): Promise<ScanResult<OpenAndIssuingMiningRoundsResponse>> {
    return this.post<OpenAndIssuingMiningRoundsResponse>(
      "/api/scan/v0/open-and-issuing-mining-rounds",
      {
        cached_open_mining_round_contract_ids: cachedOpenIds,
        cached_issuing_round_contract_ids: cachedIssuingIds,
      },
    );
  }

  // ── Amulet rules ──────────────────────────────────────────────────────────

  async getAmuletRules(): Promise<ScanResult<unknown>> {
    return this.post("/api/scan/v0/amulet-rules", {});
  }

  // ── ANS rules ─────────────────────────────────────────────────────────────

  async getAnsRules(): Promise<ScanResult<unknown>> {
    return this.post("/api/scan/v0/ans-rules", {});
  }

  // ── Transfers ────────────────────────────────────────────────────────────

  async getTransfers(pageSize = 50, cursor?: ScanCursor): Promise<ScanResult<unknown>> {
    const body: Record<string, unknown> = { page_size: pageSize };
    if (cursor) body["after"] = cursor;
    return this.post("/api/scan/v0/transfers", body);
  }

  // ── Validator reward coupons ──────────────────────────────────────────────

  async getValidatorRewardCoupons(pageSize = 50): Promise<ScanResult<unknown>> {
    return this.post("/api/scan/v0/validator-reward-coupons", { page_size: pageSize });
  }

  // ── App reward coupons ────────────────────────────────────────────────────

  async getAppRewardCoupons(pageSize = 50): Promise<ScanResult<unknown>> {
    return this.post("/api/scan/v0/app-reward-coupons", { page_size: pageSize });
  }

  // ── Helper: extract reward events from updates stream ────────────────────
  // Parses a batch of ScanUpdates and returns structured reward info

  extractRewardEvents(updates: ScanUpdate[]): Array<{
    update_id: string;
    record_time: string;
    migration_id: number;
    party_id: string;
    template: string;
    amount: string | null;
    round: string | null;
  }> {
    const results = [];
    for (const update of updates) {
      for (const event of Object.values(update.events_by_id)) {
        if (event.event_type !== "created_event") continue;
        if (!matchesTemplate(event.template_id, REWARD_TEMPLATES)) continue;

        const args = event.create_arguments ?? {};
        const party =
          (args["validator"] as string) ??
          (args["app"] as string) ??
          (args["sv"] as string) ??
          null;
        const amount =
          (args["amount"] as string) ?? (args["featuredAppActivityAmount"] as string) ?? null;
        const round = args["round"]
          ? String((args["round"] as Record<string, unknown>)["number"] ?? args["round"])
          : null;

        if (!party) continue;

        results.push({
          update_id: update.update_id,
          record_time: update.record_time,
          migration_id: update.migration_id,
          party_id: party,
          template: templateShortName(event.template_id),
          amount,
          round,
        });
      }
    }
    return results;
  }

  // ── Helper: extract transfer events from updates stream ───────────────────

  extractTransferEvents(updates: ScanUpdate[]): Array<{
    update_id: string;
    record_time: string;
    migration_id: number;
    sender: string | null;
    receivers: string[];
    amount: string | null;
  }> {
    const results = [];
    for (const update of updates) {
      for (const event of Object.values(update.events_by_id)) {
        if (event.event_type !== "exercised_event") continue;
        if (!event.choice.includes("Transfer")) continue;

        const args = event.choice_argument ?? {};
        const sender = (args["sender"] as string) ?? null;
        const outputs = args["outputs"] as Array<Record<string, unknown>> | undefined;
        const receivers = outputs?.map((o) => o["receiver"] as string).filter(Boolean) ?? [];
        const amount = outputs
          ? String(outputs.reduce((s, o) => s + parseFloat(String(o["amount"] ?? 0)), 0))
          : null;

        results.push({
          update_id: update.update_id,
          record_time: update.record_time,
          migration_id: update.migration_id,
          sender,
          receivers,
          amount,
        });
      }
    }
    return results;
  }
}

export const scan = new ScanCollector();
