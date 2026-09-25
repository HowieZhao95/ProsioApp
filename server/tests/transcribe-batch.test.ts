import { randomUUID } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { transcribeMock } = vi.hoisted(() => ({ transcribeMock: vi.fn() }));

// POST /api/transcribe (via lib/gateway.ts's transcribeBatch) calls
// experimental_transcribe from "ai" with gateway.transcriptionModel(...).
// There's no AI_GATEWAY_API_KEY in this environment, so every call is
// mocked here; it runs for real once a key is set (see server/README.md).
vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, experimental_transcribe: transcribeMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => ({
    transcriptionModel: vi.fn((id: string) => ({ modelId: id })),
  }),
}));

import { HEAD, POST } from "@/app/api/transcribe/route";
import { getStore, resetStoreForTests } from "@/lib/store";
import { authedUser, jsonRequest, makeWavBase64 } from "./helpers";

describe("POST /api/transcribe", () => {
  beforeEach(() => {
    resetStoreForTests();
    transcribeMock.mockReset();
    transcribeMock.mockResolvedValue({ text: "帮我回复一下，明天上午十点可以。", language: "zh" });
  });

  it("401s without a session token", async () => {
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio: "x", sessionID: randomUUID() }));
    expect(res.status).toBe(401);
  });

  it("400s on a missing sessionID", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }) }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("400s on non-base64 audio", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: "not base64!!! ###", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("400s on a non-WAV payload", async () => {
    const user = await authedUser();
    const audio = Buffer.from("this is not a wav file").toString("base64");
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("400s on the wrong sample rate (Gemini batch requires 16kHz mono PCM16)", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ sampleRate: 24000, sampleCount: 24000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("400s on stereo audio", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ channels: 2, sampleCount: 16000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("413s on audio over 120s", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 * 121 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(413);
    expect((await res.json()).error.code).toBe("payload_too_large");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("402s when the monthly quota is already used up", async () => {
    const user = await authedUser();
    const store = getStore();
    await store.recordUsage(user.id, {
      sessionID: randomUUID(),
      engineID: "cloud.gemini-3.5-transcribe",
      audioSeconds: 999999,
      startedAt: new Date().toISOString(),
    });

    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(402);
    expect((await res.json()).error.code).toBe("quota_exceeded");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("502s as a structured upstream_error when the Gateway call fails", async () => {
    transcribeMock.mockRejectedValue(new Error("Missing AI_GATEWAY_API_KEY"));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(502);
    expect((await res.json()).error.code).toBe("upstream_error");
  });

  it("happy path: returns text/language/durationSeconds and records usage once", async () => {
    const user = await authedUser();
    const sessionID = randomUUID();
    const audio = makeWavBase64({ sampleCount: 16000 * 2 }); // 2s of silence @ 16kHz

    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID, vocabulary: ["Prosio"] }, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.text).toBe("帮我回复一下，明天上午十点可以。");
    expect(body.language).toBe("zh");
    expect(body.durationSeconds).toBeCloseTo(2, 1);

    expect(transcribeMock).toHaveBeenCalledTimes(1);
    const call = transcribeMock.mock.calls[0]![0];
    expect(call.providerOptions.google.mode).toBe("SMART");
    expect(call.providerOptions.google.customVocabulary).toEqual(["Prosio"]);

    const store = getStore();
    const { periodStart, periodEnd } = (await import("@/lib/entitlements")).currentBillingPeriod();
    const used = await store.sumUsage(user.id, periodStart, periodEnd);
    expect(used).toBeCloseTo(2, 1);
  });

  it("does not record usage twice for the same sessionID", async () => {
    const user = await authedUser();
    const sessionID = randomUUID();
    const audio = makeWavBase64({ sampleCount: 16000 });

    await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID }, user.authHeader));
    await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID }, user.authHeader));

    const store = getStore();
    const { periodStart, periodEnd } = (await import("@/lib/entitlements")).currentBillingPeriod();
    const used = await store.sumUsage(user.id, periodStart, periodEnd);
    expect(used).toBeCloseTo(1, 1); // not 2x
  });

  it("defaults mode to smart and omits empty vocabulary/languageHints from providerOptions", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));

    const call = transcribeMock.mock.calls[0]![0];
    expect(call.providerOptions.google.mode).toBe("SMART");
    expect(call.providerOptions.google.customVocabulary).toBeUndefined();
    expect(call.providerOptions.google.languageCodes).toBeUndefined();
  });
});

describe("HEAD /api/transcribe", () => {
  it("204s with no auth", async () => {
    const res = await HEAD();
    expect(res.status).toBe(204);
  });
});
