import { beforeEach, describe, expect, it, vi } from "vitest";

const { evaluateMock } = vi.hoisted(() => ({ evaluateMock: vi.fn() }));

// POST /api/route (via lib/router.ts) calls experimental_evaluate from "ai"
// with gateway.evaluationModel("typesafe-ai/jev"). There's no
// AI_GATEWAY_API_KEY in this environment, so every call is mocked here; it
// runs for real once a key is set (see server/README.md and the live
// calibration in eval/route-cases.json / scripts/route-eval.ts).
vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, experimental_evaluate: evaluateMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => ({
    evaluationModel: vi.fn((id: string) => ({ modelId: id })),
  }),
}));

import { POST } from "@/app/api/route/route";
import { authedUser, jsonRequest } from "./helpers";

function booleanAnswers(clean: number, recognized: number) {
  return {
    answers: {
      clean: { type: "boolean", probability: clean },
      recognized: { type: "boolean", probability: recognized },
    },
  };
}

describe("POST /api/route", () => {
  beforeEach(() => {
    evaluateMock.mockReset();
  });

  it("401s without a session token", async () => {
    const res = await POST(jsonRequest("/api/route", "POST", { localTranscript: "hi" }));
    expect(res.status).toBe(401);
    expect(evaluateMock).not.toHaveBeenCalled();
  });

  it("400s on a missing localTranscript", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/route", "POST", {}, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("400s on a transcript over 4000 chars", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/route", "POST", { localTranscript: "x".repeat(4001) }, user.authHeader)
    );
    expect(res.status).toBe(400);
  });

  it("clean transcript: needsCloud=false, reason=clean", async () => {
    evaluateMock.mockResolvedValue(booleanAnswers(0.95, 0.97));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/route", "POST", { localTranscript: "好的，收到。" }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.needsCloud).toBe(false);
    expect(body.reason).toBe("clean");
    expect(body.cleanProbability).toBeCloseTo(0.95);
    expect(typeof body.latencyMs).toBe("number");
  });

  it("exactly at the 0.8 threshold counts as clean (>=)", async () => {
    evaluateMock.mockResolvedValue(booleanAnswers(0.8, 0.9));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/route", "POST", { localTranscript: "ok" }, user.authHeader));
    const body = await res.json();
    expect(body.needsCloud).toBe(false);
    expect(body.reason).toBe("clean");
  });

  it("messy transcript with clean formatting-only issue: needsCloud=true, reason=needs-cleanup", async () => {
    evaluateMock.mockResolvedValue(booleanAnswers(0.3, 0.9));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/route", "POST", { localTranscript: "嗯那个，我们周三，不对，周四开会" }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.needsCloud).toBe(true);
    expect(body.reason).toBe("needs-cleanup");
    expect(body.cleanProbability).toBeCloseTo(0.3);
  });

  it("messy transcript with a likely recognition error: needsCloud=true, reason=likely-misrecognized", async () => {
    evaluateMock.mockResolvedValue(booleanAnswers(0.2, 0.15));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/route", "POST", { localTranscript: "讨论一下超病温度的最后问题" }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.needsCloud).toBe(true);
    expect(body.reason).toBe("likely-misrecognized");
  });

  it("Jev error: 200 with needsCloud=true, reason=router-error", async () => {
    evaluateMock.mockRejectedValue(new Error("upstream boom"));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/route", "POST", { localTranscript: "hi" }, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.needsCloud).toBe(true);
    expect(body.reason).toBe("router-error");
    expect(body.cleanProbability).toBeNull();
  });

  it("Jev timeout (>1.5s): 200 with needsCloud=true, reason=router-error", async () => {
    // Mimics a real (unmocked) evaluate(): rejects when the caller's
    // abortSignal fires, rather than just hanging forever like a naive
    // mock would (which would make this test hang instead of exercising
    // the 1.5s timeout path).
    evaluateMock.mockImplementation(
      ({ abortSignal }: { abortSignal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          abortSignal?.addEventListener("abort", () => reject(new Error("The operation was aborted")));
        })
    );
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/route", "POST", { localTranscript: "hi" }, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.needsCloud).toBe(true);
    expect(body.reason).toBe("router-error");
  }, 3000);

  it("passes transcript/vocabulary/languageHints through as the evaluation state", async () => {
    evaluateMock.mockResolvedValue(booleanAnswers(0.9, 0.9));
    const user = await authedUser();
    await POST(
      jsonRequest(
        "/api/route",
        "POST",
        { localTranscript: "hello", vocabulary: ["Prosio"], languageHints: ["en-US"] },
        user.authHeader
      )
    );
    const call = evaluateMock.mock.calls[0]![0];
    expect(call.state).toEqual({ transcript: "hello", languageHints: ["en-US"], vocabulary: ["Prosio"] });
    expect(Object.keys(call.questions)).toEqual(expect.arrayContaining(["clean", "recognized"]));
  });
});
