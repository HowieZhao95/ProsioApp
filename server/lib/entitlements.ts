// Entitlements stub for P0. Every signed-in user is on the "trial" plan with
// a fixed monthly audio quota. No billing/plan storage yet.
//
// TODO(P1): replace with verified billing entitlements; the trial is not a paid plan.

export interface Entitlement {
  plan: "trial";
  /** Seconds of audio allowed per calendar month. */
  audioSecondsLimit: number;
}

const TRIAL_AUDIO_SECONDS_LIMIT = 3600;

export async function getEntitlement(_userId: string): Promise<Entitlement> {
  return { plan: "trial", audioSecondsLimit: TRIAL_AUDIO_SECONDS_LIMIT };
}

/** Start (inclusive) and end (exclusive) of the current UTC calendar month. */
export function currentBillingPeriod(now: Date = new Date()): { periodStart: Date; periodEnd: Date } {
  const periodStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const periodEnd = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  return { periodStart, periodEnd };
}

/** Technical abuse guard, covers accepted model operations, separate from audio minutes and pricing. */
export function modelRequestLimit(): number {
  const value = process.env.PROSIO_MODEL_REQUESTS_LIMIT;
  if (value === undefined && process.env.NODE_ENV !== "production" && process.env.VERCEL_ENV !== "production") return 200;
  const limit = Number(value);
  if (!Number.isSafeInteger(limit) || limit <= 0 || limit > 100000) {
    throw new Error("PROSIO_MODEL_REQUESTS_LIMIT must be a positive integer <= 100000");
  }
  return limit;
}
