import { beforeEach, describe, expect, it } from "vitest";
import { GET, POST } from "@/app/api/usage/route";
import { resetStoreForTests } from "@/lib/store";
import { authedUser, jsonRequest } from "./helpers";

describe("/api/usage", () => {
  beforeEach(() => {
    resetStoreForTests();
  });

  it("POST 401s without auth", async () => {
    const res = await POST(jsonRequest("/api/usage", "POST", {}));
    expect(res.status).toBe(401);
  });

  it("GET 401s without auth", async () => {
    const res = await GET(jsonRequest("/api/usage", "GET"));
    expect(res.status).toBe(401);
  });

  it("POST 400s on an invalid body", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/usage", "POST", { sessionID: "not-a-uuid" }, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("POST 204s and GET reflects the reported usage", async () => {
    const user = await authedUser();
    const sessionID = crypto.randomUUID();
    const postRes = await POST(
      jsonRequest(
        "/api/usage",
        "POST",
        { sessionID, engineID: "cloud.gemini-3.5-transcribe", audioSeconds: 12.3, startedAt: new Date().toISOString() },
        user.authHeader
      )
    );
    expect(postRes.status).toBe(204);
    expect(await postRes.text()).toBe("");

    const getRes = await GET(jsonRequest("/api/usage", "GET", undefined, user.authHeader));
    expect(getRes.status).toBe(200);
    const body = await getRes.json();
    expect(body.audioSecondsUsed).toBeCloseTo(12.3);
    expect(body.audioSecondsLimit).toBe(3600);
    expect(typeof body.periodStart).toBe("string");
    expect(typeof body.periodEnd).toBe("string");
  });

  it("POST is idempotent on sessionID", async () => {
    const user = await authedUser();
    const sessionID = crypto.randomUUID();
    const report = { sessionID, engineID: "cloud.gemini-3.5-transcribe", audioSeconds: 10, startedAt: new Date().toISOString() };

    await POST(jsonRequest("/api/usage", "POST", report, user.authHeader));
    // Same sessionID, different audioSeconds: should NOT be double-counted or overwritten additively.
    await POST(jsonRequest("/api/usage", "POST", { ...report, audioSeconds: 999 }, user.authHeader));

    const getRes = await GET(jsonRequest("/api/usage", "GET", undefined, user.authHeader));
    const body = await getRes.json();
    expect(body.audioSecondsUsed).toBeCloseTo(10);
  });

  it("scopes usage per user", async () => {
    const userA = await authedUser();
    const userB = await authedUser();
    await POST(
      jsonRequest(
        "/api/usage",
        "POST",
        { sessionID: crypto.randomUUID(), engineID: "e", audioSeconds: 42, startedAt: new Date().toISOString() },
        userA.authHeader
      )
    );

    const bBody = await (await GET(jsonRequest("/api/usage", "GET", undefined, userB.authHeader))).json();
    expect(bBody.audioSecondsUsed).toBe(0);
  });
});
