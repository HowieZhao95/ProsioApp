import { ApiError } from "../errors";
import type { CachedCloudResponse, CloudClaim, CloudReservation } from "./cloud-types";
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
  private operations = new Map<string, { request: CloudReservation; response?: CachedCloudResponse }>();
  private textRequests = new Map<string, number>();
  private dictionaries = new Map<string, Map<string, DictionaryEntry>>();

  async reserveCloud(request: CloudReservation): Promise<CloudClaim> {
    const key = `${request.userId}:${request.sessionID}`;
    const existing = this.operations.get(key);
    if (existing) {
      if (existing.request.fingerprint !== request.fingerprint) throw new ApiError("conflict", "Session ID belongs to a different request");
      if (existing.response) return { kind: "replay", response: existing.response };
      throw new ApiError("conflict", "Session is already processing");
    }
    if (this.usageBySessionID.has(key)) throw new ApiError("conflict", "Session ID already accounted");
    // No await before mutation: this is atomic within the dev/test process.
    let used = 0;
    for (const event of this.usageBySessionID.values()) {
      const date = new Date(event.startedAt);
      if (event.userId === request.userId && date >= request.periodStart && date < request.periodEnd) used += event.audioSeconds;
    }
    for (const operation of this.operations.values()) {
      if (!operation.response && operation.request.userId === request.userId &&
          +operation.request.periodStart === +request.periodStart) used += operation.request.seconds;
    }
    if (used + request.seconds > request.limit || used >= request.limit) throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
    this.operations.set(key, { request });
    return { kind: "claimed" };
  }

  async finishCloud(userId: string, sessionID: string, response: CachedCloudResponse, succeeded: boolean): Promise<void> {
    const operation = this.operations.get(`${userId}:${sessionID}`);
    if (!operation || operation.response) return;
    if (succeeded) {
      const request = operation.request;
      // Keep authoritative timestamps in the reserved billing period, even across midnight.
      this.usageBySessionID.set(`${userId}:${sessionID}`, { userId, sessionID,
        engineID: "cloud.gemini-3.5-transcribe", audioSeconds: request.seconds,
        startedAt: request.periodStart.toISOString() });
    }
    operation.response = structuredClone(response);
  }

  async consumeModelRequest(userId: string, periodStart: Date, limit: number): Promise<void> {
    const key = `${userId}:${periodStart.toISOString()}`;
    const used = this.textRequests.get(key) ?? 0;
    if (used >= limit) throw new ApiError("quota_exceeded", "Monthly model request limit exhausted");
    this.textRequests.set(key, used + 1);
  }

  async sumModelRequests(userId: string, periodStart: Date): Promise<number> {
    return this.textRequests.get(`${userId}:${periodStart.toISOString()}`) ?? 0;
  }

  async findOrCreateUser(email: string): Promise<User> {
    const existing = this.usersByEmail.get(email);
    if (existing) return existing;
    const user: User = { id: randomUUID(), email };
    this.usersByEmail.set(email, user);
    this.usersById.set(user.id, user);
    return user;
  }

  async recordUsage(userId: string, event: UsageEvent): Promise<void> {
    if (this.usageBySessionID.has(`${userId}:${event.sessionID}`)) {
      return; // idempotent
    }
    this.usageBySessionID.set(`${userId}:${event.sessionID}`, { ...event, userId });
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
