import { randomUUID } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { transcribe, streamText } = vi.hoisted(() => ({ transcribe: vi.fn(), streamText: vi.fn() }));
vi.mock("ai", async (original) => ({
  ...await original<typeof import("ai")>(),
  experimental_transcribe: transcribe,
  streamText,
  experimental_evaluate: vi.fn().mockRejectedValue(new Error("offline audit")),
  generateText: vi.fn().mockRejectedValue(new Error("offline audit")),
}));
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => Object.assign((id: string) => ({ modelId: id }), {
    transcriptionModel: (id: string) => ({ modelId: id }),
    evaluationModel: (id: string) => ({ modelId: id }),
  }),
}));
import { POST as transcribePost } from "@/app/api/transcribe/route";
import { POST as composePost } from "@/app/api/compose/route";
import { POST as usagePost } from "@/app/api/usage/route";
import { POST as devAuthPost } from "@/app/api/auth/dev/route";
import { currentBillingPeriod } from "@/lib/entitlements";
import { resetJevCircuitBreakerForTests } from "@/lib/jev";
import { getStore, resetStoreForTests } from "@/lib/store";
import { authedUser, jsonRequest, makeWavBase64 } from "../tests/helpers";

beforeEach(() => {
  resetStoreForTests();
  resetJevCircuitBreakerForTests();
  transcribe.mockReset().mockResolvedValue({ text: "A simple sentence.", language: "en" });
  streamText.mockReset().mockImplementation(() => ({
    textStream: new ReadableStream<string>({ start(controller) { controller.enqueue("Answer"); controller.close(); } }),
    text: Promise.resolve("Answer"),
  }));
});

async function used(userId: string) {
  const { periodStart, periodEnd } = currentBillingPeriod();
  return getStore().sumUsage(userId, periodStart, periodEnd);
}

describe("P1 launch requirements (opt-in; failures expose remaining blockers)", () => {
  it("rejects a recording that exceeds the remaining quota before model inference", async () => {
    const user = await authedUser();
    await getStore().recordUsage(user.id, { sessionID: randomUUID(), engineID: "audit", audioSeconds: 3599, startedAt: new Date().toISOString() });
    const response = await transcribePost(jsonRequest("/api/transcribe", "POST", {
      audio: makeWavBase64({ sampleCount: 16000 * 2 }), sessionID: randomUUID(),
    }, user.authHeader));
    expect(response.status).toBe(402);
    expect(transcribe).not.toHaveBeenCalled();
  });

  it("rejects empty audio before inference", async () => {
    const user = await authedUser();
    const response = await transcribePost(jsonRequest("/api/transcribe", "POST", {
      audio: makeWavBase64({ sampleCount: 0 }), sessionID: randomUUID(),
    }, user.authHeader));
    expect(response.status).toBe(400);
    expect(transcribe).not.toHaveBeenCalled();
  });

  it("does not spend model money again for a replayed session ID", async () => {
    const user = await authedUser();
    const body = { audio: makeWavBase64(), sessionID: randomUUID() };
    for (let i = 0; i < 2; i++) {
      const response = await transcribePost(jsonRequest("/api/transcribe", "POST", body, user.authHeader));
      expect(response.status).toBe(200);
    }
    expect(await used(user.id)).toBe(1);
    expect(transcribe).toHaveBeenCalledTimes(1);
  });

  it("does not let client-reported zero usage preempt authoritative cloud accounting", async () => {
    const user = await authedUser();
    const sessionID = randomUUID();
    await usagePost(jsonRequest("/api/usage", "POST", {
      sessionID, engineID: "audit", audioSeconds: 0, startedAt: new Date().toISOString(),
    }, user.authHeader));
    const response = await transcribePost(jsonRequest("/api/transcribe", "POST", {
      audio: makeWavBase64(), sessionID,
    }, user.authHeader));
    expect(response.status).toBe(200);
    expect(await used(user.id)).toBe(1);
  });

  it("meters repeated compose requests separately from audio minutes", async () => {
    const user = await authedUser();
    for (let i = 0; i < 3; i++) {
      const response = await composePost(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "Hello" }, user.authHeader));
      expect(response.status).toBe(200);
      await response.text();
    }
    expect(streamText).toHaveBeenCalledTimes(3);
    const { periodStart } = currentBillingPeriod();
    expect(await getStore().sumModelRequests(user.id, periodStart)).toBe(3);
    expect(await used(user.id)).toBe(0);
  });

  it("keeps dev sign-in disabled when PROSIO_DEV_AUTH is absent", async () => {
    const previous = process.env.PROSIO_DEV_AUTH;
    delete process.env.PROSIO_DEV_AUTH;
    try {
      const response = await devAuthPost(jsonRequest("/api/auth/dev", "POST", { email: "audit@example.com" }));
      expect(response.status).toBe(404);
    } finally {
      if (previous === undefined) delete process.env.PROSIO_DEV_AUTH;
      else process.env.PROSIO_DEV_AUTH = previous;
    }
  });
});
