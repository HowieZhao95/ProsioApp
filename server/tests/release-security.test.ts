import { randomUUID } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { POST as meetingPost } from "@/app/api/meetings/jobs/route";
import { authedUser } from "./helpers";
import { POST as devAuth } from "@/app/api/auth/dev/route";
import { signSessionToken } from "@/lib/auth";
import { toErrorResponse, ApiError } from "@/lib/errors";
import { currentBillingPeriod, modelRequestLimit } from "@/lib/entitlements";
import { readJson } from "@/lib/request-body";
import { getStore, resetStoreForTests } from "@/lib/store";
import { MemoryStore } from "@/lib/store/memory";
import type { CloudReservation } from "@/lib/store/cloud-types";
import { jsonRequest } from "./helpers";

beforeEach(() => resetStoreForTests());
afterEach(() => vi.unstubAllEnvs());

describe("production guards", () => {
  it.each(["NODE_ENV", "VERCEL_ENV"])("never enables dev impersonation in %s production", async (variable) => {
    vi.stubEnv(variable, "production");
    vi.stubEnv("PROSIO_DEV_AUTH", "1");
    expect((await devAuth(jsonRequest("/api/auth/dev", "POST", { email: "admin@example.com" }))).status).toBe(404);
  });
  it("blocks public cloud meetings until uploaded duration can be verified", async () => {
    const user = await authedUser();
    vi.stubEnv("VERCEL_ENV", "production");
    expect((await meetingPost(jsonRequest("/api/meetings/jobs", "POST", {}, user.authHeader))).status).toBe(503);
  });
  it("rejects missing persistence even when a dev store was cached", () => {
    getStore();
    vi.stubEnv("NODE_ENV", "production");
    expect(() => getStore()).toThrow("Persistent database is required");
  });
  it("rejects weak JWT signing keys in production", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PROSIO_JWT_SECRET", "short");
    await expect(signSessionToken({ id: randomUUID(), email: "test@example.com" })).rejects.toThrow("Session signing configuration is invalid");
  });
  it("requires an explicitly configured text limit in production", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("PROSIO_MODEL_REQUESTS_LIMIT", "");
    expect(() => modelRequestLimit()).toThrow();
  });
  it("does not expose unexpected errors or provider details to production clients/logs", async () => {
    vi.stubEnv("NODE_ENV", "production");
    const spy = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      for (const error of [new Error("secret-credential-in-db-url"), new ApiError("upstream_error", "secret-credential-in-db-url")]) {
        expect(await toErrorResponse(error).text()).not.toContain("secret-credential");
      }
      expect(JSON.stringify(spy.mock.calls)).not.toContain("secret-credential");
    } finally { spy.mockRestore(); }
  });
});

describe("atomic dev ledger (database implementation has a separate integration gate)", () => {
  function request(userId = randomUUID()): CloudReservation {
    return { userId, sessionID: randomUUID(), fingerprint: "a", seconds: 2, limit: 3, ...currentBillingPeriod() };
  }
  it("reserves before inference: concurrent requests cannot overdraw", async () => {
    const store = new MemoryStore();
    const a = request();
    const results = await Promise.allSettled([store.reserveCloud(a), store.reserveCloud({ ...a, sessionID: randomUUID() })]);
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(result => result.status === "rejected")).toHaveLength(1);
  });
  it("blocks concurrent duplicates, rejects payload changes, then replays results", async () => {
    const store = new MemoryStore(); const a = request();
    await store.reserveCloud(a);
    await expect(store.reserveCloud(a)).rejects.toThrow("already processing");
    await expect(store.reserveCloud({ ...a, fingerprint: "different" })).rejects.toThrow("different request");
    const response = { status: 200, body: { text: "result" } };
    await store.finishCloud(a.userId, a.sessionID, response, true);
    expect(await store.reserveCloud(a)).toEqual({ kind: "replay", response });
    expect(await store.sumUsage(a.userId, a.periodStart, a.periodEnd)).toBe(2);
  });
  it("keeps failure replay terminal without charging audio or blocking a new attempt", async () => {
    const store = new MemoryStore(); const a = request();
    await store.reserveCloud(a);
    const response = { status: 502, body: { error: { code: "upstream_error" } } };
    await store.finishCloud(a.userId, a.sessionID, response, false);
    expect(await store.reserveCloud(a)).toEqual({ kind: "replay", response });
    expect(await store.sumUsage(a.userId, a.periodStart, a.periodEnd)).toBe(0);
    expect(await store.reserveCloud({ ...a, sessionID: randomUUID() })).toEqual({ kind: "claimed" });
  });
  it("scopes session identities and usage to the user", async () => {
    const store = new MemoryStore(); const a = request(); const b = { ...a, userId: randomUUID() };
    await Promise.all([store.reserveCloud(a), store.reserveCloud(b)]);
    await Promise.all([store.finishCloud(a.userId, a.sessionID, { status: 200, body: {} }, true), store.finishCloud(b.userId, b.sessionID, { status: 200, body: {} }, true)]);
    expect(await store.sumUsage(a.userId, a.periodStart, a.periodEnd)).toBe(2);
    expect(await store.sumUsage(b.userId, b.periodStart, b.periodEnd)).toBe(2);
  });
  it("serializes text limits and keeps other users/months independent", async () => {
    const store = new MemoryStore(); const a = request();
    const attempts = await Promise.allSettled(Array.from({ length: 10 }, () => store.consumeModelRequest(a.userId, a.periodStart, 3)));
    expect(attempts.filter(result => result.status === "fulfilled")).toHaveLength(3);
    expect(await store.sumModelRequests(a.userId, a.periodStart)).toBe(3);
    await store.consumeModelRequest(randomUUID(), a.periodStart, 3);
    await store.consumeModelRequest(a.userId, a.periodEnd, 3);
  });
});

describe("request allocation bounds", () => {
  it("bounds chunked bodies even with a dishonest small Content-Length", async () => {
    const stream = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('"xxxxxxxx"')); controller.close(); } });
    const req = new Request("https://example.com", { method: "POST", headers: { "content-length": "1" }, body: stream, duplex: "half" } as RequestInit);
    await expect(readJson(req, 5)).rejects.toMatchObject({ code: "payload_too_large" });
  });
  it("returns malformed JSON as null for ordinary validation", async () => {
    expect(await readJson(new Request("https://example.com", { method: "POST", body: "{" }))).toBeNull();
  });
});
