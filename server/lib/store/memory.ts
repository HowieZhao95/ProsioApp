import { randomUUID } from "node:crypto";
import type { DictionaryEntry, Store, User, UsageEvent } from "./types";

interface StoredUsageEvent extends UsageEvent {
  userId: string;
}

/** In-memory Store implementation. Used when DATABASE_URL is absent (dev/tests). Not persisted across restarts. */
export class MemoryStore implements Store {
  private usersByEmail = new Map<string, User>();
  private usersById = new Map<string, User>();
  // sessionID -> event, for idempotency.
  private usageBySessionID = new Map<string, StoredUsageEvent>();
  private dictionaries = new Map<string, Map<string, DictionaryEntry>>();

  async findOrCreateUser(email: string): Promise<User> {
    const existing = this.usersByEmail.get(email);
    if (existing) return existing;
    const user: User = { id: randomUUID(), email };
    this.usersByEmail.set(email, user);
    this.usersById.set(user.id, user);
    return user;
  }

  async recordUsage(userId: string, event: UsageEvent): Promise<void> {
    if (this.usageBySessionID.has(event.sessionID)) {
      return; // idempotent
    }
    this.usageBySessionID.set(event.sessionID, { ...event, userId });
  }

  async sumUsage(userId: string, periodStart: Date, periodEnd: Date): Promise<number> {
    let total = 0;
    for (const event of this.usageBySessionID.values()) {
      if (event.userId !== userId) continue;
      const startedAt = new Date(event.startedAt);
      if (startedAt >= periodStart && startedAt < periodEnd) {
        total += event.audioSeconds;
      }
    }
    return total;
  }

  async getDictionary(userId: string): Promise<DictionaryEntry[]> {
    const dict = this.dictionaries.get(userId);
    if (!dict) return [];
    return [...dict.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
  }

  async putDictionary(userId: string, entries: DictionaryEntry[]): Promise<DictionaryEntry[]> {
    let dict = this.dictionaries.get(userId);
    if (!dict) {
      dict = new Map();
      this.dictionaries.set(userId, dict);
    }
    for (const incoming of entries) {
      const existing = dict.get(incoming.id);
      if (!existing || incoming.updatedAt >= existing.updatedAt) {
        dict.set(incoming.id, incoming);
      }
    }
    return this.getDictionary(userId);
  }
}
