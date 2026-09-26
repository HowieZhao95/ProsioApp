import { beforeEach, describe, expect, it, vi } from "vitest";

const { evaluateMock } = vi.hoisted(() => ({ evaluateMock: vi.fn() }));

vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, experimental_evaluate: evaluateMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => ({
    evaluationModel: vi.fn((id: string) => ({ modelId: id })),
  }),
}));

import { checkLocalTranscript } from "@/lib/transcribe-routing";
import { resetJevCircuitBreakerForTests } from "@/lib/jev";

function combinedAnswers(clean: number, recognized: number, intentChoice: string, intentProbabilities: Record<string, number>) {
  return {
    answers: {
      clean: { type: "boolean", probability: clean },
      recognized: { type: "boolean", probability: recognized },
      intent: { type: "choice", choice: intentChoice, probabilities: intentProbabilities },
    },
  };
}

describe("checkLocalTranscript", () => {
  beforeEach(() => {
    evaluateMock.mockReset();
    resetJevCircuitBreakerForTests();
  });

  it("asks all three questions (clean, recognized, intent) in ONE call", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 }));
    await checkLocalTranscript({ transcript: "hi", vocabulary: [], languageHints: [], hasSelection: false });
    expect(evaluateMock).toHaveBeenCalledTimes(1);
    const call = evaluateMock.mock.calls[0]![0];
    expect(Object.keys(call.questions)).toEqual(expect.arrayContaining(["clean", "recognized", "intent"]));
    expect(call.state).toMatchObject({ transcript: "hi", utterance: "hi", hasSelection: false });
  });

  it("offers dictate (not edit) when hasSelection is false, and vice versa", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 }));
    await checkLocalTranscript({ transcript: "hi", vocabulary: [], languageHints: [], hasSelection: false });
    expect(evaluateMock.mock.calls[0]![0].questions.intent.criteria.dictate).toBeDefined();
    expect(evaluateMock.mock.calls[0]![0].questions.intent.criteria.edit).toBeUndefined();

    evaluateMock.mockReset();
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "edit", { edit: 0.95 }));
    await checkLocalTranscript({ transcript: "hi", vocabulary: [], languageHints: [], hasSelection: true });
    expect(evaluateMock.mock.calls[0]![0].questions.intent.criteria.edit).toBeDefined();
    expect(evaluateMock.mock.calls[0]![0].questions.intent.criteria.dictate).toBeUndefined();
  });

  it("clean (>=0.9) + dictate: needsCloud=false", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 }));
    const decision = await checkLocalTranscript({ transcript: "好的收到", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(false);
    expect(decision.reason).toBe("clean");
    expect(decision.intent).toBe("dictate");
    expect(decision.intentSource).toBe("jev");
  });

  it("uses the stricter 0.9 threshold, NOT the /api/route 0.8 one — 0.85 is clean enough for /api/route but not here", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.85, 0.9, "dictate", { dictate: 0.95 }));
    const decision = await checkLocalTranscript({ transcript: "x", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(true); // 0.85 < 0.9
    expect(decision.reason).toBe("needs-cleanup");
  });

  it("clean but intent is ask: still needsCloud=false (route-wise) but caller must check intent separately", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "ask", { ask: 0.9 }));
    const decision = await checkLocalTranscript({ transcript: "what time is it", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(false); // text itself is clean
    expect(decision.intent).toBe("ask"); // but intent isn't dictate/edit — route.ts's POST handler decides to still go cloud
  });

  it("messy transcript: needsCloud=true, reason=needs-cleanup", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.3, 0.9, "dictate", { dictate: 0.6 }));
    const decision = await checkLocalTranscript({ transcript: "嗯那个", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(true);
    expect(decision.reason).toBe("needs-cleanup");
  });

  it("likely misrecognized: needsCloud=true, reason=likely-misrecognized", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.2, 0.15, "dictate", { dictate: 0.5 }));
    const decision = await checkLocalTranscript({ transcript: "讨论超病温度", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(true);
    expect(decision.reason).toBe("likely-misrecognized");
  });

  it("below-threshold intent confidence still defaults, source stays jev", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "ask", { dictate: 0.4, ask: 0.45 }));
    const decision = await checkLocalTranscript({ transcript: "x", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.intent).toBe("dictate"); // defaulted
    expect(decision.intentSource).toBe("jev");
  });

  it("Jev error: needsCloud=true, reason=router-error, intent=null, intentSource=unavailable", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    const decision = await checkLocalTranscript({ transcript: "x", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.needsCloud).toBe(true);
    expect(decision.reason).toBe("router-error");
    expect(decision.intent).toBeNull();
    expect(decision.intentConfidence).toBeNull();
    expect(decision.intentSource).toBe("unavailable");
  });

  it("shares the circuit breaker: a failure here skips a subsequent call (any Jev call) immediately", async () => {
    evaluateMock.mockRejectedValue(new Error("boom"));
    await checkLocalTranscript({ transcript: "a", vocabulary: [], languageHints: [], hasSelection: false });

    evaluateMock.mockClear();
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 })); // would succeed if called
    const decision = await checkLocalTranscript({ transcript: "b", vocabulary: [], languageHints: [], hasSelection: false });
    expect(decision.intentSource).toBe("unavailable"); // breaker open — skipped
    expect(evaluateMock).not.toHaveBeenCalled();
  });

  it("P1.2.1 list guard: an unformatted spoken list forces cloud WITHOUT calling Jev at all", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 })); // would say "clean" if asked
    const decision = await checkLocalTranscript({
      transcript: "我们讲一下以下几个要点，新版本周二上线，客服要提前培训，监控要加延迟指标",
      vocabulary: [],
      languageHints: [],
      hasSelection: false,
    });
    expect(decision.needsCloud).toBe(true);
    expect(decision.reason).toBe("needs-formatting");
    expect(decision.cleanProbability).toBeNull();
    expect(decision.intent).toBeNull();
    expect(decision.intentSource).toBe("unavailable");
    expect(evaluateMock).not.toHaveBeenCalled(); // the guard is cheaper than asking Jev, so Jev is never asked
  });

  it("P1.2.1 list guard: does not fire on an ordinary clean transcript, Jev still runs normally", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "dictate", { dictate: 0.95 }));
    const decision = await checkLocalTranscript({
      transcript: "好的，收到，谢谢。",
      vocabulary: [],
      languageHints: [],
      hasSelection: false,
    });
    expect(decision.reason).toBe("clean");
    expect(evaluateMock).toHaveBeenCalledTimes(1);
  });

  it("offers write and applies its stricter 0.8 threshold", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "write", { dictate: 0.05, write: 0.8 }));
    const decision = await checkLocalTranscript({
      transcript: "帮我回复他说明天可以，但会晚半小时到",
      vocabulary: [],
      languageHints: [],
      hasSelection: false,
    });
    expect(decision.intent).toBe("write");
    const call = evaluateMock.mock.calls[0]![0];
    expect(call.questions.intent.criteria.write).toBeDefined();
  });

  it("write below 0.8 (but above the default 0.7) defaults instead of being accepted, so it never takes the local fast path", async () => {
    evaluateMock.mockResolvedValue(combinedAnswers(0.95, 0.97, "write", { dictate: 0.2, write: 0.75 }));
    const decision = await checkLocalTranscript({
      transcript: "x",
      vocabulary: [],
      languageHints: [],
      hasSelection: false,
    });
    expect(decision.intent).toBe("dictate"); // defaulted
    expect(decision.needsCloud).toBe(false); // text itself was clean...
    // ...but app/api/transcribe's route only skips Gemini for dictate/edit,
    // so a "write" classification (accepted or defaulted away from) can
    // never reach the local fast path either way.
  });
});
