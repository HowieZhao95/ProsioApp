export interface User {
  id: string;
  email: string;
}

export interface UsageEvent {
  sessionID: string;
  engineID: string;
  audioSeconds: number;
  startedAt: string; // ISO-8601
}

/** Matches Swift `DictionaryEntry` (docs/API.md § Dictionary). */
export interface DictionaryEntry {
  id: string;
  term: string;
  note: string | null;
  createdAt: string; // ISO-8601
  updatedAt: string; // ISO-8601
}

/**
 * Storage abstraction used by every route handler. `MemoryStore` is used
 * when `DATABASE_URL` is absent (local dev, tests, CI); `PostgresStore`
 * backs real deployments.
 */
export interface Store {
  /** Finds a user by email, creating one if it doesn't exist yet (dev auth). */
  findOrCreateUser(email: string): Promise<User>;

  /**
   * Records a usage event. Idempotent on `sessionID`: a second call with the
   * same sessionID for the same user is a no-op and does not double-count.
   */
  recordUsage(userId: string, event: UsageEvent): Promise<void>;

  /** Sum of audioSeconds for events in [periodStart, periodEnd) for this user. */
  sumUsage(userId: string, periodStart: Date, periodEnd: Date): Promise<number>;

  getDictionary(userId: string): Promise<DictionaryEntry[]>;

  /**
   * Merges `entries` into the stored dictionary: for ids present in both,
   * the entry with the later `updatedAt` wins; ids only in `entries` are
   * added; ids only in storage are left untouched. Returns the full,
   * merged dictionary for the user (see server/README.md for rationale).
   */
  putDictionary(userId: string, entries: DictionaryEntry[]): Promise<DictionaryEntry[]>;
}
