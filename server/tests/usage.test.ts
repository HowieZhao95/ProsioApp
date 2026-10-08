import { beforeEach, describe, expect, it } from "vitest";
import { GET, POST } from "@/app/api/usage/route";
import { getStore, resetStoreForTests } from "@/lib/store";
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

  it("acknowledges client telemetry without trusting it as billable usage", async () => {
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
    expect(body.audioSecondsUsed).toBe(0);
    expect(body.audioSecondsLimit).toBe(3600);
    expect(typeof body.periodStart).toBe("string");
    expect(typeof body.periodEnd).toBe("string");
  });

  it("client telemetry cannot overwrite authoritative usage or double-count it", async () => {
    const user = await authedUser();
    const sessionID = crypto.randomUUID();
    const report = { sessionID, engineID: "cloud.gemini-3.5-transcribe", audioSeconds: 10, startedAt: new Date().toISOString() };

    await getStore().recordUsage(user.id, report);
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

    await getStore().recordUsage(userA.id, { sessionID: crypto.randomUUID(), engineID: "server", audioSeconds: 42, startedAt: new Date().toISOString() });
    const bBody = await (await GET(jsonRequest("/api/usage", "GET", undefined, userB.authHeader))).json();
    expect(bBody.audioSecondsUsed).toBe(0);
  });
});
