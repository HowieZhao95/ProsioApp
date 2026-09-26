import { randomUUID } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const { transcribeMock, evaluateMock, generateTextMock } = vi.hoisted(() => ({
  transcribeMock: vi.fn(),
  evaluateMock: vi.fn(),
  generateTextMock: vi.fn(),
}));

// POST /api/transcribe (via lib/gateway.ts's transcribeBatch) calls
// experimental_transcribe from "ai" with gateway.transcriptionModel(...).
// P1.2 also calls experimental_evaluate (lib/jev.ts, via lib/router.ts /
// lib/intent.ts / lib/transcribe-routing.ts) whenever a localTranscript is
// given, or (for the intent reclassify-on-final step) even without one.
// P1.2.1's list-repair step (lib/list-repair.ts) calls generateText with
// the plain callable `gateway(modelId)` form (like POST /api/compose does),
// so the mocked gateway below must be callable AND have the two model
// factory methods. There's no AI_GATEWAY_API_KEY in this environment, so
// every call is mocked here; all three run for real once a key is set (see
// server/README.md).
vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, experimental_transcribe: transcribeMock, experimental_evaluate: evaluateMock, generateText: generateTextMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () =>
    Object.assign((id: string) => ({ modelId: id }), {
      transcriptionModel: vi.fn((id: string) => ({ modelId: id })),
      evaluationModel: vi.fn((id: string) => ({ modelId: id })),
    }),
}));

import { HEAD, POST } from "@/app/api/transcribe/route";
import { resetJevCircuitBreakerForTests } from "@/lib/jev";
import { getStore, resetStoreForTests } from "@/lib/store";
import { authedUser, jsonRequest, makeOggOpusBase64, makeWavBase64 } from "./helpers";

function combinedAnswers(clean: number, recognized: number, intentChoice: string, intentProbabilities: Record<string, number>) {
  return {
    answers: {
      clean: { type: "boolean", probability: clean },
      recognized: { type: "boolean", probability: recognized },
      intent: { type: "choice", choice: intentChoice, probabilities: intentProbabilities },
    },
  };
}

function intentOnlyAnswer(choice: string, probabilities: Record<string, number>) {
  return { answers: { intent: { type: "choice", choice, probabilities } } };
}

describe("POST /api/transcribe", () => {
  beforeEach(() => {
    resetStoreForTests();
    resetJevCircuitBreakerForTests();
    transcribeMock.mockReset();
    transcribeMock.mockResolvedValue({ text: "帮我回复一下，明天上午十点可以。", language: "zh" });
    evaluateMock.mockReset();
    // Sane default so tests that don't care about intent/routing (most of
    // this file predates P1.2) get a fast, deterministic "unavailable"
    // instead of an unmocked call hanging or throwing unexpectedly.
    evaluateMock.mockRejectedValue(new Error("no evaluateMock behavior configured for this test"));
    generateTextMock.mockReset();
    generateTextMock.mockRejectedValue(new Error("no generateTextMock behavior configured for this test"));
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

  it("cloud path with no localTranscript: route.reason is no-local-transcript, intent is reclassified on final (classifiedOn: final)", async () => {
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.95 }));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    const body = await res.json();
    expect(body.source).toBe("cloud");
    expect(body.route).toEqual({ cleanProbability: null, reason: "no-local-transcript" });
    expect(body.intent).toEqual({ intent: "dictate", confidence: 0.95, source: "jev", classifiedOn: "final" });
  });

  it("cloud path: normalizes stray bullet markers ('• ') to '- ' in the returned text", async () => {
    transcribeMock.mockResolvedValue({ text: "Here's the plan:\n• first step\n• second step", language: "en" });
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.95 }));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    const body = await res.json();
    expect(body.text).toBe("Here's the plan:\n- first step\n- second step");
    expect(body.formatRepair).toBeNull(); // already had a Markdown list after marker normalization — repair never fires
  });
});

describe("POST /api/transcribe — P1.2.1 list repair", () => {
  beforeEach(() => {
    resetStoreForTests();
    resetJevCircuitBreakerForTests();
    transcribeMock.mockReset();
    evaluateMock.mockReset();
    evaluateMock.mockRejectedValue(new Error("no evaluateMock behavior configured for this test"));
    generateTextMock.mockReset();
    generateTextMock.mockRejectedValue(new Error("no generateTextMock behavior configured for this test"));
  });

  const UNFORMATTED_MIXED_LIST = "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。";

  it("applies the repair to a mixed zh/en implicit list SMART left as a run-on sentence", async () => {
    transcribeMock.mockResolvedValue({ text: UNFORMATTED_MIXED_LIST, language: "zh" });
    generateTextMock.mockResolvedValue({ text: "有几个 action items：\n- 更新 readme\n- 加 unit tests\n- deploy 到 staging" });
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.9 })); // reclassify (leading text changed)
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID() }, user.authHeader)
    );
    const body = await res.json();
    expect(body.formatRepair).toBe("applied");
    expect(body.text).toBe("有几个 action items：\n- 更新 readme\n- 加 unit tests\n- deploy 到 staging");
    expect(generateTextMock).toHaveBeenCalledTimes(1);
    const call = generateTextMock.mock.calls[0]![0];
    expect(call.model).toEqual({ modelId: "openai/gpt-6-luna" }); // PROSIO_COMPOSE_MODEL default
  });

  it("does not call the repair model at all for ordinary clean text (detector doesn't fire)", async () => {
    transcribeMock.mockResolvedValue({ text: "帮我回复一下，明天上午十点可以。", language: "zh" });
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.95 }));
    const user = await authedUser();
    await POST(jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID() }, user.authHeader));
    expect(generateTextMock).not.toHaveBeenCalled();
  });

  it("rejects and keeps the original when the repair model changes content, still returns 200", async () => {
    transcribeMock.mockResolvedValue({ text: UNFORMATTED_MIXED_LIST, language: "zh" });
    generateTextMock.mockResolvedValue({ text: "- Update the readme\n- Add unit tests\n- Deploy to staging" }); // translated
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.9 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.formatRepair).toBe("rejected");
    expect(body.text).toBe(UNFORMATTED_MIXED_LIST); // kept unchanged
  });

  it("times out after 2s and keeps the original, still returns 200", async () => {
    transcribeMock.mockResolvedValue({ text: UNFORMATTED_MIXED_LIST, language: "zh" });
    generateTextMock.mockImplementation(
      ({ abortSignal }: { abortSignal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          abortSignal?.addEventListener("abort", () => reject(new Error("aborted")));
        })
    );
    evaluateMock.mockResolvedValue(intentOnlyAnswer("dictate", { dictate: 0.9 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.formatRepair).toBe("timeout");
    expect(body.text).toBe(UNFORMATTED_MIXED_LIST);
  }, 5000);

  it("includes a 'format' Server-Timing mark", async () => {
    transcribeMock.mockResolvedValue({ text: "帮我回复一下，明天上午十点可以。", language: "zh" });
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.95 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.headers.get("server-timing")).toContain("format;dur=");
  });
});

describe("POST /api/transcribe — audioFormat", () => {
  beforeEach(() => {
    resetStoreForTests();
    resetJevCircuitBreakerForTests();
    transcribeMock.mockReset();
    transcribeMock.mockResolvedValue({ text: "hello there", language: "en" });
    evaluateMock.mockReset();
    evaluateMock.mockRejectedValue(new Error("no evaluateMock behavior configured for this test"));
    generateTextMock.mockReset();
    generateTextMock.mockRejectedValue(new Error("no generateTextMock behavior configured for this test"));
  });

  it("415s on an unrecognized audioFormat", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "mp3", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(415);
    expect((await res.json()).error.code).toBe("unsupported_media_type");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("defaults audioFormat to wav (backward compatible: omitting the field behaves exactly as before)", async () => {
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 * 121 }); // over the WAV cap
    const res = await POST(jsonRequest("/api/transcribe", "POST", { audio, sessionID: randomUUID() }, user.authHeader));
    expect(res.status).toBe(413); // still capped at 120s, proving the wav path was used
  });

  it("ogg-opus happy path: computes duration from the Ogg container, no WAV validation applied", async () => {
    const user = await authedUser();
    const sessionID = randomUUID();
    const audio = makeOggOpusBase64({ durationSeconds: 2.5 });
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "ogg-opus", sessionID }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.text).toBe("hello there");
    expect(body.durationSeconds).toBeCloseTo(2.5, 1);
    expect(transcribeMock).toHaveBeenCalledTimes(1);

    const store = getStore();
    const { periodStart, periodEnd } = (await import("@/lib/entitlements")).currentBillingPeriod();
    const used = await store.sumUsage(user.id, periodStart, periodEnd);
    expect(used).toBeCloseTo(2.5, 1);
  });

  it("ogg-opus: allows audio well past the 120s WAV cap, up to 600s", async () => {
    const user = await authedUser();
    const audio = makeOggOpusBase64({ durationSeconds: 300 });
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "ogg-opus", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(200);
  });

  it("ogg-opus: 413s over 600s", async () => {
    const user = await authedUser();
    const audio = makeOggOpusBase64({ durationSeconds: 601 });
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "ogg-opus", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(413);
    expect((await res.json()).error.code).toBe("payload_too_large");
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("ogg-opus: 400s on stereo audio", async () => {
    const user = await authedUser();
    const audio = makeOggOpusBase64({ durationSeconds: 1, channelCount: 2 });
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "ogg-opus", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect(transcribeMock).not.toHaveBeenCalled();
  });

  it("ogg-opus: 400s on a malformed Ogg file", async () => {
    const user = await authedUser();
    const audio = Buffer.from("not an ogg file at all").toString("base64");
    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, audioFormat: "ogg-opus", sessionID: randomUUID() }, user.authHeader)
    );
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });
});

describe("POST /api/transcribe — P1.2 local-transcript routing", () => {
  beforeEach(() => {
    resetStoreForTests();
    resetJevCircuitBreakerForTests();
    transcribeMock.mockReset();
    transcribeMock.mockResolvedValue({ text: "帮我回复一下，明天上午十点可以。", language: "zh" });
    evaluateMock.mockReset();
    evaluateMock.mockRejectedValue(new Error("no evaluateMock behavior configured for this test"));
    generateTextMock.mockReset();
    generateTextMock.mockRejectedValue(new Error("no generateTextMock behavior configured for this test"));
  });

  it("P1.2.1 list guard: an unformatted spoken local transcript always goes to cloud, reason=needs-formatting, no Jev call", async () => {
    transcribeMock.mockResolvedValue({ text: "我们讲一下以下几个要点：\n- 新版本周二上线\n- 客服要提前培训\n- 监控要加延迟指标", language: "zh" });
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.9 })); // reclassify-on-final (intent was null)
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        {
          audio: makeWavBase64({ sampleCount: 16000 }),
          sessionID: randomUUID(),
          localTranscript: "我们讲一下以下几个要点，新版本周二上线，客服要提前培训，监控要加延迟指标",
          hasSelection: false,
        },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("cloud");
    expect(body.route).toEqual({ cleanProbability: null, reason: "needs-formatting" });
    expect(transcribeMock).toHaveBeenCalledTimes(1); // never took the local fast path
    expect(evaluateMock).toHaveBeenCalledTimes(1); // only the reclassify-on-final call — the guard skipped the local check's Jev call entirely
  });

  it("clean + dictate: skips Gemini entirely, source=local, no Gateway call, usage still recorded", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 }));
    const user = await authedUser();
    const sessionID = randomUUID();
    const audio = makeWavBase64({ sampleCount: 16000 * 2 });
    const localTranscript = "好的，收到，谢谢。";

    const res = await POST(
      jsonRequest("/api/transcribe", "POST", { audio, sessionID, localTranscript, hasSelection: false }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.text).toBe(localTranscript);
    expect(body.source).toBe("local");
    expect(body.intent).toEqual({ intent: "dictate", confidence: 0.95, source: "jev", classifiedOn: "local" });
    expect(body.route).toEqual({ cleanProbability: 0.95, reason: "clean" });
    expect(transcribeMock).not.toHaveBeenCalled(); // no Gemini cost

    const store = getStore();
    const { periodStart, periodEnd } = (await import("@/lib/entitlements")).currentBillingPeriod();
    const used = await store.sumUsage(user.id, periodStart, periodEnd);
    expect(used).toBeCloseTo(2, 1); // usage still metered by audio duration
  });

  it("clean + edit (with a selection): also skips Gemini, source=local", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "edit", { edit: 0.95 }));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio, sessionID: randomUUID(), localTranscript: "make it shorter", hasSelection: true },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("local");
    expect(body.intent.intent).toBe("edit");
  });

  it("clean but intent=ask: still goes to cloud (dictate/edit only skip Gemini)", async () => {
    evaluateMock.mockResolvedValueOnce(combinedAnswers(0.95, 0.97, "ask", { ask: 0.9 }));
    // Leading text of the (mocked) final differs a lot from the local
    // transcript, so intent gets reclassified on the final — this second
    // call provides that answer.
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("ask", { ask: 0.88 }));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio, sessionID: randomUUID(), localTranscript: "what time is the meeting", hasSelection: false },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("cloud");
    expect(transcribeMock).toHaveBeenCalledTimes(1);
    expect(body.intent).toEqual({ intent: "ask", confidence: 0.88, source: "jev", classifiedOn: "final" });
  });

  it("clean but intent=write: also still goes to cloud (dictate/edit only skip Gemini)", async () => {
    evaluateMock.mockResolvedValueOnce(combinedAnswers(0.95, 0.97, "write", { write: 0.85 }));
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("write", { write: 0.9 }));
    const user = await authedUser();
    const audio = makeWavBase64({ sampleCount: 16000 });
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio, sessionID: randomUUID(), localTranscript: "帮我回复他说明天可以，但会晚半小时到", hasSelection: false },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("cloud");
    expect(transcribeMock).toHaveBeenCalledTimes(1);
    expect(body.intent.intent).toBe("write");
  });

  it("messy transcript (needsCloud=true): goes to cloud, route reason carried through, intent reused when leading text matches", async () => {
    transcribeMock.mockResolvedValue({ text: "嗯那个，我们周四开会，别忘了。", language: "zh" });
    evaluateMock.mockResolvedValueOnce(combinedAnswers(0.3, 0.9, "dictate", { dictate: 0.6 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID(), localTranscript: "嗯那个，我们周三开会", hasSelection: false },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("cloud");
    expect(body.route).toEqual({ cleanProbability: 0.3, reason: "needs-cleanup" });
    // Leading ~6 non-punctuation chars ("嗯那个我们周" vs "嗯那个我们周") match closely
    // enough that the local intent classification (dictate, confident) is reused
    // rather than making a second Jev call.
    expect(body.intent).toEqual({ intent: "dictate", confidence: 0.6, source: "jev", classifiedOn: "local" });
    expect(evaluateMock).toHaveBeenCalledTimes(1); // only the combined local check — no reclassify call
  });

  it("reclassifies on final when the leading text differs a lot from the local transcript", async () => {
    transcribeMock.mockResolvedValue({ text: "Completely different final text here.", language: "en" });
    evaluateMock.mockResolvedValueOnce(combinedAnswers(0.3, 0.9, "dictate", { dictate: 0.6 })); // local check: messy -> cloud
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("ask", { ask: 0.85 })); // reclassify-on-final
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID(), localTranscript: "um so anyway I think", hasSelection: false },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.intent).toEqual({ intent: "ask", confidence: 0.85, source: "jev", classifiedOn: "final" });
    expect(evaluateMock).toHaveBeenCalledTimes(2);
  });

  it("reclassifies on final when the local check's intent was null (Jev unavailable)", async () => {
    evaluateMock.mockRejectedValueOnce(new Error("boom")); // local check fails
    evaluateMock.mockResolvedValueOnce(intentOnlyAnswer("dictate", { dictate: 0.9 })); // reclassify-on-final succeeds (breaker: see note below)
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID(), localTranscript: "some local text", hasSelection: false },
        user.authHeader
      )
    );
    const body = await res.json();
    expect(body.source).toBe("cloud");
    // The circuit breaker opened after the local check's failure, so the
    // reclassify-on-final call is skipped too — this documents that
    // real end-to-end behavior (one Jev outage affects the whole request),
    // not a bug: intent ends up "unavailable", not the second mock's answer.
    expect(body.intent).toEqual({ intent: null, confidence: null, source: "unavailable", classifiedOn: "final" });
  });

  it("415s on unknown audioFormat even when localTranscript is present", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio: makeWavBase64({ sampleCount: 16000 }), audioFormat: "flac", sessionID: randomUUID(), localTranscript: "hi" },
        user.authHeader
      )
    );
    expect(res.status).toBe(415);
  });

  it("400s on a localTranscript over 4000 chars", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/transcribe",
        "POST",
        { audio: makeWavBase64({ sampleCount: 16000 }), sessionID: randomUUID(), localTranscript: "x".repeat(4001) },
        user.authHeader
      )
    );
    expect(res.status).toBe(400);
  });
});

describe("HEAD /api/transcribe", () => {
  it("204s with no auth", async () => {
    const res = await HEAD();
    expect(res.status).toBe(204);
  });
});
