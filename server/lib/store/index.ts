import { MemoryStore } from "./memory";
import { PostgresStore } from "./postgres";
import type { Store } from "./types";

export type { DictionaryEntry, Store, User, UsageEvent } from "./types";

let cached: Store | undefined;

/**
 * Returns the process-wide Store singleton: PostgresStore when DATABASE_URL
 * is set, otherwise an in-memory store (used for local dev without a
 * database, and for tests).
 */
export function getStore(): Store {
  if (!cached) {
    const url = process.env.DATABASE_URL;
    cached = url ? new PostgresStore(url) : new MemoryStore();
  }
  return cached;
}

/** Test-only: reset the singleton so each test file starts from a clean store. */
export function resetStoreForTests(): void {
  cached = undefined;
}
