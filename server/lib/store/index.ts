import { ApiError } from "../errors";
import { MemoryStore } from "./memory";
import { PostgresStore } from "./postgres";
import type { Store } from "./types";

export type { DictionaryEntry, Store, User, UsageEvent } from "./types";

let cached: Store | undefined;
let cachedURL: string | undefined;

/**
 * Returns the process-wide Store singleton: PostgresStore when DATABASE_URL
 * is set, otherwise an in-memory store (used for local dev without a
 * database, and for tests).
 */
export function getStore(): Store {
  const url = process.env.DATABASE_URL;
  if ((process.env.NODE_ENV === "production" || process.env.VERCEL_ENV === "production") && !url) {
    throw new ApiError("unavailable", "Persistent database is required");
  }
  if (!cached || cachedURL !== url) {
    cachedURL = url;
    cached = url ? new PostgresStore(url) : new MemoryStore();
  }
  return cached;
}

/** Test-only: reset the singleton so each test file starts from a clean store. */
export function resetStoreForTests(): void {
  cached = undefined;
  cachedURL = undefined;
}
