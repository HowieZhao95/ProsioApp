import { beforeEach, describe, expect, it } from "vitest";
import { GET, PUT } from "@/app/api/dictionary/route";
import { resetStoreForTests } from "@/lib/store";
import { authedUser, jsonRequest } from "./helpers";

function entry(overrides: Partial<Record<string, unknown>> = {}) {
  const now = new Date().toISOString();
  return {
    id: crypto.randomUUID(),
    term: "Prosio",
    note: null,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}

describe("/api/dictionary", () => {
  beforeEach(() => {
    resetStoreForTests();
  });

  it("GET 401s without auth", async () => {
    const res = await GET(jsonRequest("/api/dictionary", "GET"));
    expect(res.status).toBe(401);
  });

  it("GET returns an empty list initially", async () => {
    const user = await authedUser();
    const res = await GET(jsonRequest("/api/dictionary", "GET", undefined, user.authHeader));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ entries: [] });
  });

  it("PUT rejects a term over 100 chars", async () => {
    const user = await authedUser();
    const res = await PUT(
      jsonRequest("/api/dictionary", "PUT", { entries: [entry({ term: "x".repeat(101) })] }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("PUT rejects more than 1000 entries", async () => {
    const user = await authedUser();
    const entries = Array.from({ length: 1001 }, () => entry());
    const res = await PUT(jsonRequest("/api/dictionary", "PUT", { entries }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("PUT then GET round-trips entries", async () => {
    const user = await authedUser();
    const e = entry({ term: "Vercel" });
    const putRes = await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [e] }, user.authHeader));
    expect(putRes.status).toBe(200);
    expect(await putRes.json()).toEqual({ entries: [e] });

    const getRes = await GET(jsonRequest("/api/dictionary", "GET", undefined, user.authHeader));
    expect(await getRes.json()).toEqual({ entries: [e] });
  });

  it("last-write-wins by updatedAt per id: a stale update is ignored", async () => {
    const user = await authedUser();
    const id = crypto.randomUUID();
    const older = entry({ id, term: "Old", updatedAt: "2024-01-01T00:00:00.000Z" });
    const newer = entry({ id, term: "New", updatedAt: "2024-06-01T00:00:00.000Z" });

    await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [newer] }, user.authHeader));
    const res = await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [older] }, user.authHeader));
    const body = await res.json();
    expect(body.entries).toHaveLength(1);
    expect(body.entries[0].term).toBe("New"); // stale write did not overwrite the newer one
  });

  it("last-write-wins by updatedAt per id: a newer update is applied", async () => {
    const user = await authedUser();
    const id = crypto.randomUUID();
    const older = entry({ id, term: "Old", updatedAt: "2024-01-01T00:00:00.000Z" });
    const newer = entry({ id, term: "New", updatedAt: "2024-06-01T00:00:00.000Z" });

    await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [older] }, user.authHeader));
    const res = await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [newer] }, user.authHeader));
    const body = await res.json();
    expect(body.entries).toHaveLength(1);
    expect(body.entries[0].term).toBe("New");
  });

  it("scopes dictionaries per user", async () => {
    const userA = await authedUser();
    const userB = await authedUser();
    await PUT(jsonRequest("/api/dictionary", "PUT", { entries: [entry()] }, userA.authHeader));

    const bRes = await GET(jsonRequest("/api/dictionary", "GET", undefined, userB.authHeader));
    expect(await bRes.json()).toEqual({ entries: [] });
  });
});
