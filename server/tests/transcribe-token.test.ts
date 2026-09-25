import { beforeEach, describe, expect, it, vi } from "vitest";

const { getTokenMock } = vi.hoisted(() => ({ getTokenMock: vi.fn() }));

// The route (via lib/gateway.ts) calls gateway.experimental_transcription.getToken(...).
// We never have a real AI_GATEWAY_API_KEY in this environment, so every
// Gateway call is mocked here; the real thing "just works" once a key is set
// (see server/README.md).
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => ({
    experimental_transcription: {
      getToken: getTokenMock,
    },
  }),
}));

import { POST } from "@/app/api/transcribe/token/route";
import { resetStoreForTests, getStore } from "@/lib/store";
import { authedUser, jsonRequest } from "./helpers";

describe("POST /api/transcribe/token", () => {
  beforeEach(() => {
    resetStoreForTests();
    getTokenMock.mockReset();
  });

  it("401s without a session token", async () => {
    const res = await POST(jsonRequest("/api/transcribe/token", "POST", {}));
    expect(res.status).toBe(401);
    expect((await res.json()).error.code).toBe("unauthorized");
  });

  it("400s for a non-allow-listed model", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe/token", "POST", { model: "nope/not-allowed" }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
    expect(getTokenMock).not.toHaveBeenCalled();
  });

  it("mints a token on the happy path, defaulting the model", async () => {
    getTokenMock.mockResolvedValue({
      token: "vcst_test123",
      url: "wss://gateway.example/transcribe",
      expiresAt: Math.floor(Date.now() / 1000) + 300,
    });
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/transcribe/token", "POST", {}, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({
      token: "vcst_test123",
      url: "wss://gateway.example/transcribe",
      model: "google/gemini-3.5-transcribe-live",
    });
    expect(typeof body.expiresAt).toBe("string");
    expect(getTokenMock).toHaveBeenCalledWith(
      expect.objectContaining({ model: "google/gemini-3.5-transcribe-live" })
    );
  });

  it("computes expiresAt when the SDK omits it", async () => {
    getTokenMock.mockResolvedValue({ token: "vcst_noexp", url: "wss://gateway.example/transcribe" });
    const user = await authedUser();
    const before = Date.now();
    const res = await POST(jsonRequest("/api/transcribe/token", "POST", {}, user.authHeader));
    const body = await res.json();
    expect(res.status).toBe(200);
    expect(new Date(body.expiresAt).getTime()).toBeGreaterThan(before);
  });

  it("402s when the monthly quota is already used up", async () => {
    const user = await authedUser();
    const store = getStore();
    await store.recordUsage(user.id, {
      sessionID: crypto.randomUUID(),
      engineID: "gateway.gemini-3.5-transcribe-live",
      audioSeconds: 999999,
      startedAt: new Date().toISOString(),
    });

    const res = await POST(jsonRequest("/api/transcribe/token", "POST", {}, user.authHeader));
    expect(res.status).toBe(402);
    expect((await res.json()).error.code).toBe("quota_exceeded");
    expect(getTokenMock).not.toHaveBeenCalled();
  });

  it("502s as a structured upstream_error when the Gateway call fails (e.g. missing API key)", async () => {
    getTokenMock.mockRejectedValue(new Error("Missing AI_GATEWAY_API_KEY"));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/transcribe/token", "POST", {}, user.authHeader));
    expect(res.status).toBe(502);
    const body = await res.json();
    expect(body.error.code).toBe("upstream_error");
  });
});
