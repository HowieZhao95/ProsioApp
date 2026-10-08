/** Internal server ledger; no client-supplied event can modify it. */
export interface CloudReservation {
  userId: string;
  sessionID: string;
  fingerprint: string;
  seconds: number;
  limit: number;
  periodStart: Date;
  periodEnd: Date;
}
export interface CachedCloudResponse {
  status: number;
  body: unknown;
}
export type CloudClaim = { kind: "claimed" } | { kind: "replay"; response: CachedCloudResponse };
