// Entitlements stub for P0. Every signed-in user is on the "trial" plan with
// a fixed monthly audio quota. No billing/plan storage yet.
//
// TODO(P1): RevenueCat — replace with real plan lookup (subscription status,
// per-plan quota) once RevenueCat webhooks/receipts are wired up.

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
