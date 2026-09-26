import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { evaluateMock } = vi.hoisted(() => ({ evaluateMock: vi.fn() }));

// POST /api/intent (via lib/intent.ts) calls experimental_evaluate from
// "ai" with gateway.evaluationModel("typesafe-ai/jev"). There's no
// AI_GATEWAY_API_KEY in this environment, so every call is mocked here; it
// runs for real once a key is set.
vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, experimental_evaluate: evaluateMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => ({
    evaluationModel: vi.fn((id: string) => ({ modelId: id })),
  }),
}));

import { POST } from "@/app/api/intent/route";
import { BREAKER_COOLDOWN_MS, classifyIntent, resetIntentCircuitBreakerForTests } from "@/lib/intent";
import { authedUser, jsonRequest } from "./helpers";

function choiceAnswer(choice: string, probabilities: Record<string, number>) {
  return { answers: { intent: { type: "choice", choice, probabilities } } };
}

describe("POST /api/intent", () => {
  beforeEach(() => {
    evaluateMock.mockReset();
    // Every test starts from a clean circuit breaker — otherwise a
    // preceding test's Jev failure/timeout would leave the breaker "open"
    // and silently skip Jev in a later test that expects it to be called.
    resetIntentCircuitBreakerForTests();
  });

  it("401s without a session token", async () => {
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "hi", hasSelection: false }));
    expect(res.status).toBe(401);
    expect(evaluateMock).not.toHaveBeenCalled();
  });

  it("400s on a missing transcript", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { hasSelection: false }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("400s on a transcript over 4000 chars", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "x".repeat(4001), hasSelection: false }, user.authHeader)
    );
    expect(res.status).toBe(400);
  });

  it("400s on a missing hasSelection", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "hi" }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("high-confidence dictate: no selection, dictate offered", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.95, ask: 0.03, translate: 0.02 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "hey are we still on for lunch", hasSelection: false }, user.authHeader)
    );
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ intent: "dictate", source: "jev" });
    expect(body.confidence).toBeCloseTo(0.95);
    expect(typeof body.latencyMs).toBe("number");

    const call = evaluateMock.mock.calls[0]![0];
    expect(Object.keys(call.questions.intent.criteria)).toEqual(expect.arrayContaining(["dictate", "ask", "translate"]));
    expect(call.questions.intent.criteria.edit).toBeUndefined(); // not offered when hasSelection=false
  });

  it("high-confidence edit: selection present, edit offered instead of dictate", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("edit", { edit: 0.9, ask: 0.05, translate: 0.05 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "make it shorter", hasSelection: true }, user.authHeader)
    );
    const body = await res.json();
    expect(body).toMatchObject({ intent: "edit", source: "jev" });

    const call = evaluateMock.mock.calls[0]![0];
    expect(call.questions.intent.criteria.dictate).toBeUndefined();
    expect(call.questions.intent.criteria.edit).toBeDefined();
  });

  it("high-confidence ask and translate", async () => {
    evaluateMock.mockResolvedValueOnce(choiceAnswer("ask", { dictate: 0.05, ask: 0.9, translate: 0.05 }));
    const user = await authedUser();
    let res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "Prosio, what's the capital of France", hasSelection: false }, user.authHeader)
    );
    expect((await res.json()).intent).toBe("ask");

    evaluateMock.mockResolvedValueOnce(choiceAnswer("translate", { dictate: 0.05, ask: 0.05, translate: 0.9 }));
    res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "translate this to Japanese", hasSelection: false }, user.authHeader)
    );
    expect((await res.json()).intent).toBe("translate");
  });

  it("below-threshold confidence: falls back to the default, but source is still jev", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("ask", { dictate: 0.35, ask: 0.4, translate: 0.25 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "ambiguous utterance", hasSelection: false }, user.authHeader)
    );
    const body = await res.json();
    expect(body.intent).toBe("dictate"); // default for !hasSelection
    expect(body.source).toBe("jev"); // Jev DID answer — just below threshold
    expect(body.confidence).toBeCloseTo(0.4); // raw probability still reported
  });

  it("below-threshold confidence with a selection: defaults to edit", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("ask", { edit: 0.3, ask: 0.35, translate: 0.35 }));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/intent", "POST", { transcript: "ambiguous utterance", hasSelection: true }, user.authHeader)
    );
    const body = await res.json();
    expect(body.intent).toBe("edit");
    expect(body.source).toBe("jev");
  });

  it("exactly at the 0.7 threshold counts as confident (>=)", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("translate", { dictate: 0.15, ask: 0.15, translate: 0.7 }));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "x", hasSelection: false }, user.authHeader));
    const body = await res.json();
    expect(body.intent).toBe("translate");
  });

  it("Jev error: 200 with intent=null, source=unavailable, confidence=null", async () => {
    evaluateMock.mockRejectedValue(new Error("upstream boom"));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "hi", hasSelection: false }, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ intent: null, confidence: null, source: "unavailable" });
    expect(typeof body.latencyMs).toBe("number");
  });

  it("Jev timeout (>1.2s): 200 with intent=null, source=unavailable", async () => {
    evaluateMock.mockImplementation(
      ({ abortSignal }: { abortSignal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          abortSignal?.addEventListener("abort", () => reject(new Error("The operation was aborted")));
        })
    );
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "hi", hasSelection: false }, user.authHeader));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ intent: null, source: "unavailable" });
  }, 3000);

  it("Jev returns an unoffered choice: treated as an error (unavailable)", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.9 })); // hasSelection=true won't offer "dictate"
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "x", hasSelection: true }, user.authHeader));
    const body = await res.json();
    expect(body.source).toBe("unavailable");
  });

  it("Jev returns a non-choice answer shape: treated as an error (unavailable)", async () => {
    evaluateMock.mockResolvedValue({ answers: { intent: { type: "boolean", probability: 0.9 } } });
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/intent", "POST", { transcript: "x", hasSelection: false }, user.authHeader));
    const body = await res.json();
    expect(body.source).toBe("unavailable");
  });
});

describe("classifyIntent — circuit breaker", () => {
  beforeEach(() => {
    evaluateMock.mockReset();
    resetIntentCircuitBreakerForTests();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("stays closed and keeps calling Jev while it succeeds", async () => {
    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.9 }));
    await classifyIntent({ transcript: "a", hasSelection: false });
    await classifyIntent({ transcript: "b", hasSelection: false });
    expect(evaluateMock).toHaveBeenCalledTimes(2);
  });

  it("opens after a failure: the very next call skips Jev entirely and returns unavailable immediately", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    const first = await classifyIntent({ transcript: "a", hasSelection: false });
    expect(first.source).toBe("unavailable");
    expect(evaluateMock).toHaveBeenCalledTimes(1);

    evaluateMock.mockClear();
    const second = await classifyIntent({ transcript: "b", hasSelection: false });
    expect(second.source).toBe("unavailable");
    expect(second.latencyMs).toBeLessThan(5); // no network call, no 1.2s timeout wait
    expect(evaluateMock).not.toHaveBeenCalled(); // breaker skipped Jev
  });

  it("opens after a timeout too (not just an explicit error)", async () => {
    evaluateMock.mockImplementation(
      ({ abortSignal }: { abortSignal?: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          abortSignal?.addEventListener("abort", () => reject(new Error("aborted")));
        })
    );
    const pending = classifyIntent({ transcript: "a", hasSelection: false });
    await vi.advanceTimersByTimeAsync(1200);
    const first = await pending;
    expect(first.source).toBe("unavailable");

    evaluateMock.mockClear();
    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.9 })); // would succeed if called
    const second = await classifyIntent({ transcript: "b", hasSelection: false });
    expect(second.source).toBe("unavailable"); // still skipped — breaker is open
    expect(evaluateMock).not.toHaveBeenCalled();
  });

  it("stays open for the full cooldown, then probes exactly once and closes on success", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    await classifyIntent({ transcript: "a", hasSelection: false }); // opens the breaker

    evaluateMock.mockClear();
    await vi.advanceTimersByTimeAsync(BREAKER_COOLDOWN_MS - 1000);
    const stillCooling = await classifyIntent({ transcript: "b", hasSelection: false });
    expect(stillCooling.source).toBe("unavailable");
    expect(evaluateMock).not.toHaveBeenCalled(); // still within the 60s window

    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.9 }));
    await vi.advanceTimersByTimeAsync(1000); // now past the full cooldown
    const probe = await classifyIntent({ transcript: "c", hasSelection: false });
    expect(probe.source).toBe("jev"); // the probe succeeded
    expect(evaluateMock).toHaveBeenCalledTimes(1);

    // Breaker is closed again — the next call goes straight to Jev, no skip.
    evaluateMock.mockClear();
    const after = await classifyIntent({ transcript: "d", hasSelection: false });
    expect(after.source).toBe("jev");
    expect(evaluateMock).toHaveBeenCalledTimes(1);
  });

  it("re-opens for another full cooldown if the probe itself fails", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    await classifyIntent({ transcript: "a", hasSelection: false }); // opens the breaker

    await vi.advanceTimersByTimeAsync(BREAKER_COOLDOWN_MS); // cooldown elapses
    evaluateMock.mockClear();
    evaluateMock.mockRejectedValue(new Error("still down")); // probe also fails
    const probe = await classifyIntent({ transcript: "b", hasSelection: false });
    expect(probe.source).toBe("unavailable");
    expect(evaluateMock).toHaveBeenCalledTimes(1);

    // Immediately after the failed probe, the breaker should be open again
    // (skipping Jev), not closed.
    evaluateMock.mockClear();
    evaluateMock.mockResolvedValue(choiceAnswer("dictate", { dictate: 0.9 })); // would succeed if called
    const rightAfter = await classifyIntent({ transcript: "c", hasSelection: false });
    expect(rightAfter.source).toBe("unavailable");
    expect(evaluateMock).not.toHaveBeenCalled();

    // A full new cooldown later, it probes again.
    await vi.advanceTimersByTimeAsync(BREAKER_COOLDOWN_MS);
    evaluateMock.mockClear();
    const secondProbe = await classifyIntent({ transcript: "d", hasSelection: false });
    expect(secondProbe.source).toBe("jev");
    expect(evaluateMock).toHaveBeenCalledTimes(1);
  });

  it("a below-threshold (but successful) Jev answer still closes the breaker", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    await classifyIntent({ transcript: "a", hasSelection: false }); // opens the breaker

    await vi.advanceTimersByTimeAsync(BREAKER_COOLDOWN_MS);
    evaluateMock.mockClear();
    evaluateMock.mockResolvedValue(choiceAnswer("ask", { dictate: 0.4, ask: 0.45 })); // below 0.7 threshold
    const probe = await classifyIntent({ transcript: "b", hasSelection: false });
    expect(probe.source).toBe("jev"); // Jev DID answer — success for the breaker
    expect(probe.intent).toBe("dictate"); // defaulted, since below threshold

    evaluateMock.mockClear();
    const after = await classifyIntent({ transcript: "c", hasSelection: false });
    expect(evaluateMock).toHaveBeenCalledTimes(1); // breaker closed, calls Jev normally
    expect(after.source).toBe("jev");
  });
});
