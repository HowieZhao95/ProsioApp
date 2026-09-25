import { neon } from "@neondatabase/serverless";
import { and, eq, gte, lt, sql } from "drizzle-orm";
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
  private db: ReturnType<typeof drizzle>;

  constructor(connectionString: string) {
    const sqlClient = neon(connectionString);
    this.db = drizzle(sqlClient);
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
      .onConflictDoNothing({ target: usageEvents.sessionId });
  }

  async sumUsage(userId: string, periodStart: Date, periodEnd: Date): Promise<number> {
    const rows = await this.db
      .select({ total: sql<string>`coalesce(sum(${usageEvents.audioSeconds}), 0)` })
      .from(usageEvents)
      .where(
        and(
          eq(usageEvents.userId, userId),
          gte(usageEvents.startedAt, periodStart),
          lt(usageEvents.startedAt, periodEnd)
        )
      );
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
