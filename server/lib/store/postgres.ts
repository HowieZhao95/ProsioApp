import { ApiError } from "../errors";
import type { CachedCloudResponse, CloudClaim, CloudReservation } from "./cloud-types";
import { neon, type NeonQueryFunction } from "@neondatabase/serverless";
import { eq, sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/neon-http";
import { dictionaryEntries, usageEvents, users } from "./schema";
import type { DictionaryEntry, Store, User, UsageEvent } from "./types";

/**
 * Postgres-backed Store (Neon serverless driver + drizzle). Used when
 * DATABASE_URL is set. This is a P0 skeleton: it type-checks and is wired
 * up correctly, but is not exercised by the test suite (no live database in
 * this environment) — see server/README.md.
 */
export class PostgresStore implements Store {
  private sqlClient: NeonQueryFunction<false, false>;
  private db: ReturnType<typeof drizzle>;

  constructor(connectionString: string) {
    const sqlClient = neon(connectionString);
    this.sqlClient = sqlClient;
    this.db = drizzle(sqlClient);
  }

  async reserveCloud(request: CloudReservation): Promise<CloudClaim> {
    const sqlClient = this.sqlClient;
    try {
      const rows = await sqlClient`SELECT * FROM reserve_cloud_operation(
        ${request.userId}::uuid, ${request.sessionID}::uuid, ${request.fingerprint},
        ${request.periodStart.toISOString()}::timestamptz, ${request.periodEnd.toISOString()}::timestamptz,
        ${request.seconds}, ${request.limit})`;
      const row = rows[0];
      if (!row) throw new ApiError("unavailable", "Cloud ledger unavailable");
      if (row.operation_state === "pending" && !row.was_created) throw new ApiError("conflict", "Session is already processing");
      return row.was_created ? { kind: "claimed" } : { kind: "replay", response: row.cached_response as CachedCloudResponse };
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (code === "P0001") throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
      if (code === "P0003") throw new ApiError("conflict", "Session ID belongs to a different request");
      throw error;
    }
  }

  async finishCloud(userId: string, sessionID: string, response: CachedCloudResponse, succeeded: boolean): Promise<void> {
    const sqlClient = this.sqlClient;
    await sqlClient`SELECT finish_cloud_operation(${userId}::uuid, ${sessionID}::uuid,
      ${JSON.stringify(response)}::jsonb, ${succeeded})`;
  }

  async consumeModelRequest(userId: string, periodStart: Date, limit: number): Promise<void> {
    const sqlClient = this.sqlClient;
    try {
      await sqlClient`SELECT consume_model_request(${userId}::uuid, ${periodStart.toISOString()}::timestamptz, ${limit})`;
    } catch (error) {
      if ((error as { code?: string }).code === "P0001") throw new ApiError("quota_exceeded", "Monthly model request limit exhausted");
      throw error;
    }
  }

  async sumModelRequests(userId: string, periodStart: Date): Promise<number> {
    const sqlClient = this.sqlClient;
    const rows = await sqlClient`SELECT requests FROM model_request_usage WHERE user_id = ${userId}::uuid AND period_start = ${periodStart.toISOString()}::timestamptz`;
    return Number(rows[0]?.requests ?? 0);
  }

  async findOrCreateUser(email: string): Promise<User> {
    const existing = await this.db.select().from(users).where(eq(users.email, email)).limit(1);
    if (existing[0]) {
      return { id: existing[0].id, email: existing[0].email };
    }
    const inserted = await this.db
      .insert(users)
      .values({ email })
      .onConflictDoUpdate({ target: users.email, set: { email } })
      .returning();
    const row = inserted[0]!;
    return { id: row.id, email: row.email };
  }

  async recordUsage(userId: string, event: UsageEvent): Promise<void> {
    await this.db
      .insert(usageEvents)
      .values({
        userId,
        sessionId: event.sessionID,
        engineId: event.engineID,
        audioSeconds: event.audioSeconds,
        startedAt: new Date(event.startedAt),
      })
      .onConflictDoNothing({ target: [usageEvents.userId, usageEvents.sessionId] });
  }

  async sumUsage(userId: string, periodStart: Date, periodEnd: Date): Promise<number> {
    const sqlClient = this.sqlClient;
    const rows = await sqlClient`SELECT
      coalesce((SELECT sum(audio_seconds) FROM usage_events WHERE user_id = ${userId}::uuid
        AND started_at >= ${periodStart.toISOString()}::timestamptz AND started_at < ${periodEnd.toISOString()}::timestamptz), 0)
      + coalesce((SELECT sum(reserved_seconds) FROM meeting_jobs WHERE user_id = ${userId}::uuid
        AND period_start = ${periodStart.toISOString()}::timestamptz AND status = 'completed'), 0) AS total`;
    return Number(rows[0]?.total ?? 0);
  }

  async getDictionary(userId: string): Promise<DictionaryEntry[]> {
    const rows = await this.db
      .select()
      .from(dictionaryEntries)
      .where(eq(dictionaryEntries.userId, userId))
      .orderBy(dictionaryEntries.createdAt);
    return rows.map(toDictionaryEntry);
  }

  async putDictionary(userId: string, entries: DictionaryEntry[]): Promise<DictionaryEntry[]> {
    for (const entry of entries) {
      await this.db
        .insert(dictionaryEntries)
        .values({
          id: entry.id,
          userId,
          term: entry.term,
          note: entry.note,
          createdAt: new Date(entry.createdAt),
          updatedAt: new Date(entry.updatedAt),
        })
        .onConflictDoUpdate({
          target: [dictionaryEntries.userId, dictionaryEntries.id],
          set: {
            term: entry.term,
            note: entry.note,
            updatedAt: new Date(entry.updatedAt),
          },
          // Last-write-wins by updatedAt: only overwrite if the incoming
          // entry is not older than what's stored.
          setWhere: sql`${dictionaryEntries.updatedAt} <= ${new Date(entry.updatedAt).toISOString()}`,
        });
    }
    return this.getDictionary(userId);
  }
}

function toDictionaryEntry(row: typeof dictionaryEntries.$inferSelect): DictionaryEntry {
  return {
    id: row.id,
    term: row.term,
    note: row.note,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}
