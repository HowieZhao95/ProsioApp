import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { streamTextMock } = vi.hoisted(() => ({ streamTextMock: vi.fn() }));

// POST /api/compose calls streamText from "ai" with gateway(modelId). No
// AI_GATEWAY_API_KEY in this environment, so every model call is mocked
// here; it runs for real once a key is set (see server/README.md and the
// live model-selection eval in eval/compose-cases.json / scripts/compose-eval.ts).
vi.mock("ai", async (importOriginal) => {
  const actual = await importOriginal<typeof import("ai")>();
  return { ...actual, streamText: streamTextMock };
});
vi.mock("@ai-sdk/gateway", () => ({
  createGateway: () => (id: string) => ({ modelId: id }),
}));

import { POST } from "@/app/api/compose/route";
import { authedUser, jsonRequest } from "./helpers";

/** A real ReadableStream<string> — createTextStreamResponse calls .pipeThrough on it, so a plain async iterable won't do. */
function textStreamFrom(chunks: string[], failAfter?: Error): ReadableStream<string> {
  return new ReadableStream<string>({
    start(controller) {
      for (const c of chunks) controller.enqueue(c);
      if (failAfter) controller.error(failAfter);
      else controller.close();
    },
  });
}

function mockStreamTextResult(chunks: string[], failAfter?: Error) {
  const fullText = chunks.join("");
  const text = failAfter ? Promise.reject(failAfter) : Promise.resolve(fullText);
  // Route code under test awaits `text` separately (ask mode only) and
  // still observes the rejection there; this just stops Vitest flagging it
  // as an unhandled rejection in tests (like "502s...") that never touch
  // `.text` at all, since the mock always creates a fresh promise eagerly.
  text.catch(() => {});
  return { textStream: textStreamFrom(chunks, failAfter), text };
}

describe("POST /api/compose", () => {
  beforeEach(() => {
    streamTextMock.mockReset();
    streamTextMock.mockReturnValue(mockStreamTextResult(["hello world"]));
  });

  afterEach(() => {
    delete process.env.PROSIO_COMPOSE_MODEL;
    delete process.env.PROSIO_ASK_MODEL;
  });

  it("401s without a session token", async () => {
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "hi", scene: "chat" }));
    expect(res.status).toBe(401);
    expect(streamTextMock).not.toHaveBeenCalled();
  });

  it("400s on missing text", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", scene: "chat" }, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("400s on text over 8000 chars", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x".repeat(8001), scene: "chat" }, user.authHeader)
    );
    expect(res.status).toBe(400);
  });

  it("400s on edit without a selection", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "edit", text: "make it shorter" }, user.authHeader));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("bad_request");
  });

  it("400s on translate without targetLanguage", async () => {
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "translate", text: "hello" }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("400s on selection over 20000 chars", async () => {
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "edit", text: "shorten", selection: "x".repeat(20001) }, user.authHeader)
    );
    expect(res.status).toBe(400);
  });

  it("400s on more than 20 history turns", async () => {
    const user = await authedUser();
    const history = Array.from({ length: 21 }, (_, i) => ({ role: "user" as const, text: `turn ${i}` }));
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "ask", text: "hi", history }, user.authHeader));
    expect(res.status).toBe(400);
  });

  it("rewrite: non-ask output is sanitized (wrapping quotes stripped) and fully buffered", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(['"Meeting moved', " to Thursday.\""]));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader)
    );
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/plain");
    expect(res.headers.get("x-prosio-model")).toBeTruthy();
    expect(res.headers.get("server-timing")).toContain("total;dur=");
    const body = await res.text();
    expect(body).toBe("Meeting moved to Thursday.");
  });

  it("rewrite: strips a single wrapping code fence", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["```\nhello\n```"]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader));
    expect(await res.text()).toBe("hello");
  });

  it("rewrite: normalizes stray bullet markers ('* ') to '- ' in the final output", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["Intro:\n* first item\n* second item"]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader));
    expect(await res.text()).toBe("Intro:\n- first item\n- second item");
  });

  it("translateCommand: targetLanguage is optional (defaults server-side), still sanitized like other non-ask modes", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["Let's meet tomorrow morning."]));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "translateCommand", text: "帮我翻成英语 我们明天早上见" }, user.authHeader)
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("Let's meet tomorrow morning.");
  });

  it("translateCommand: honors an explicit targetLanguage when given", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["我们明天见"]));
    const user = await authedUser();
    const res = await POST(
      jsonRequest(
        "/api/compose",
        "POST",
        { mode: "translateCommand", text: "translate to Chinese: see you tomorrow", targetLanguage: "zh-CN" },
        user.authHeader
      )
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("我们明天见");
  });

  it("ask: streams deltas through live, unsanitized", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(['"quoted', " answer\""]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "ask", text: "what time is it?" }, user.authHeader));
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/plain");
    // Server-Timing for ask is sent before the model responds: auth+prompt only, no "total" (would be misleading — see route comment).
    expect(res.headers.get("server-timing")).not.toContain("total;dur=");
    const body = await res.text();
    expect(body).toBe('"quoted answer"'); // NOT sanitized — ask streams live, quotes and all
  });

  it("402s when the monthly quota is already used up", async () => {
    const { getStore, resetStoreForTests } = await import("@/lib/store");
    resetStoreForTests();
    const user = await authedUser();
    const store = getStore();
    await store.recordUsage(user.id, {
      sessionID: crypto.randomUUID(),
      engineID: "cloud.gemini-3.5-transcribe",
      audioSeconds: 999999,
      startedAt: new Date().toISOString(),
    });
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader));
    expect(res.status).toBe(402);
    expect(streamTextMock).not.toHaveBeenCalled();
  });

  it("502s (structured) when the model stream fails mid-way, for non-ask", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["partial"], new Error("upstream boom")));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader));
    expect(res.status).toBe(502);
    expect((await res.json()).error.code).toBe("upstream_error");
  });

  it("uses PROSIO_COMPOSE_MODEL for non-ask modes", async () => {
    process.env.PROSIO_COMPOSE_MODEL = "test/compose-model";
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader));
    expect(res.headers.get("x-prosio-model")).toBe("test/compose-model");
    expect(streamTextMock.mock.calls[0]![0].model).toEqual({ modelId: "test/compose-model" });
  });

  it("PROSIO_ASK_MODEL overrides PROSIO_COMPOSE_MODEL for ask only", async () => {
    process.env.PROSIO_COMPOSE_MODEL = "test/compose-model";
    process.env.PROSIO_ASK_MODEL = "test/ask-model";
    const user = await authedUser();

    streamTextMock.mockReturnValueOnce(mockStreamTextResult(["ok"]));
    const askRes = await POST(jsonRequest("/api/compose", "POST", { mode: "ask", text: "hi" }, user.authHeader));
    expect(askRes.headers.get("x-prosio-model")).toBe("test/ask-model");
    await askRes.text(); // drain the body so the mocked stream fully settles before the next call

    streamTextMock.mockReturnValueOnce(mockStreamTextResult(["ok"]));
    const rewriteRes = await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "x", scene: "chat" }, user.authHeader)
    );
    expect(rewriteRes.headers.get("x-prosio-model")).toBe("test/compose-model");
  });

  it("passes temperature 0.2 for non-ask and 0.4 for ask, for a model that supports it", async () => {
    // Use an env-overridden model outside MODELS_WITHOUT_TEMPERATURE (the
    // default, openai/gpt-6-luna, is a reasoning model that never gets a
    // temperature — see the dedicated test below) so this test is about
    // temperature plumbing, not tied to whichever model happens to be default.
    process.env.PROSIO_COMPOSE_MODEL = "test/compose-model";
    process.env.PROSIO_ASK_MODEL = "test/compose-model";
    const user = await authedUser();
    await POST(jsonRequest("/api/compose", "POST", { mode: "edit", text: "fix", selection: "a somewhat longer selection so length checks behave" }, user.authHeader));
    expect(streamTextMock.mock.calls[0]![0].temperature).toBe(0.2);

    streamTextMock.mockReturnValue(mockStreamTextResult(["ok"]));
    await POST(jsonRequest("/api/compose", "POST", { mode: "ask", text: "hi" }, user.authHeader));
    expect(streamTextMock.mock.calls[1]![0].temperature).toBe(0.4);
  });

  it("omits temperature and sets reasoningEffort=none for openai/gpt-6-luna (the default)", async () => {
    const user = await authedUser();
    await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "hello there, how are you doing today", scene: "chat" }, user.authHeader)
    );
    const call = streamTextMock.mock.calls[0]![0];
    expect(call.temperature).toBeUndefined();
    expect(call.providerOptions).toEqual({ openai: { reasoningEffort: "none" } });
  });
});

describe("POST /api/compose — guardrails (luna's observed failure modes)", () => {
  beforeEach(() => {
    streamTextMock.mockReset();
  });

  afterEach(() => {
    delete process.env.PROSIO_COMPOSE_MODEL;
    delete process.env.PROSIO_ASK_MODEL;
    delete process.env.PROSIO_COMPOSE_FALLBACK_MODEL;
  });

  it("empty primary output: retries with the fallback model, uses its output", async () => {
    streamTextMock
      .mockReturnValueOnce(mockStreamTextResult([""])) // primary: empty
      .mockReturnValueOnce(mockStreamTextResult(["Meeting moved to Thursday."])); // fallback: good
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "meeting moved to thursday", scene: "chat" }, user.authHeader)
    );
    expect(await res.text()).toBe("Meeting moved to Thursday.");
    expect(res.headers.get("x-prosio-fallback")).toBeNull();
    expect(res.headers.get("x-prosio-model")).toBe("openai/gpt-5.4-mini");
    expect(streamTextMock).toHaveBeenCalledTimes(2);
  });

  it("empty output from BOTH primary and fallback: returns the original text unchanged, X-Prosio-Fallback: empty", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["   "])); // whitespace-only, both calls
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "meeting moved to thursday", scene: "chat" }, user.authHeader)
    );
    expect(await res.text()).toBe("meeting moved to thursday");
    expect(res.headers.get("x-prosio-fallback")).toBe("empty");
    expect(streamTextMock).toHaveBeenCalledTimes(2);
  });

  it("edit drift (ASCII bar chart the selection didn't contain): retries with fallback, uses its clean output", async () => {
    streamTextMock
      .mockReturnValueOnce(mockStreamTextResult(["Revenue grew steadily this quarter.\n\nRevenue trend:\n▂ ▃ ▄ ▅ ▆"]))
      .mockReturnValueOnce(mockStreamTextResult(["Revenue grew steadily this quarter."]));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "edit", text: "add a bar chart showing the trend", selection: "Revenue grew steadily this quarter." }, user.authHeader)
    );
    expect(await res.text()).toBe("Revenue grew steadily this quarter.");
    expect(res.headers.get("x-prosio-fallback")).toBeNull();
    expect(res.headers.get("x-prosio-model")).toBe("openai/gpt-5.4-mini");
  });

  it("edit drift on BOTH attempts: returns the selection unchanged, X-Prosio-Fallback: drift", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult(["Revenue grew steadily.\n\n```\n▁ ▂ ▃ ▄█\n```"]));
    const user = await authedUser();
    const res = await POST(
      jsonRequest("/api/compose", "POST", { mode: "edit", text: "add a bar chart showing the trend", selection: "Revenue grew steadily this quarter." }, user.authHeader)
    );
    expect(await res.text()).toBe("Revenue grew steadily this quarter.");
    expect(res.headers.get("x-prosio-fallback")).toBe("drift");
  });

  it("edit output 3x+ the selection length (no expansion requested): treated as drift", async () => {
    const selection = "This is a normal length selection that a user might have picked to edit.";
    streamTextMock
      .mockReturnValueOnce(mockStreamTextResult(["x".repeat(selection.length * 4)]))
      .mockReturnValueOnce(mockStreamTextResult(["A modestly edited version of the selection."]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "edit", text: "make it better", selection }, user.authHeader));
    expect(await res.text()).toBe("A modestly edited version of the selection.");
  });

  it("does NOT flag drift when the instruction explicitly asks to expand", async () => {
    const selection = "我们应该采用这个方案。";
    streamTextMock.mockReturnValue(
      mockStreamTextResult(["我们应该采用这个方案，因为它成本更低、实施周期更短，并且已经在同行业中得到验证，能够显著降低项目风险。"])
    );
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "edit", text: "扩写一下，补充理由", selection }, user.authHeader));
    expect(res.headers.get("x-prosio-fallback")).toBeNull();
    expect(streamTextMock).toHaveBeenCalledTimes(1);
  });

  it("ask mode: no guard/retry on empty output, just streams it through (logged server-side)", async () => {
    streamTextMock.mockReturnValue(mockStreamTextResult([""]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "ask", text: "hi" }, user.authHeader));
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("");
    expect(streamTextMock).toHaveBeenCalledTimes(1); // no fallback retry for ask
  });

  it("respects PROSIO_COMPOSE_FALLBACK_MODEL override", async () => {
    process.env.PROSIO_COMPOSE_FALLBACK_MODEL = "test/custom-fallback";
    streamTextMock.mockReturnValueOnce(mockStreamTextResult([""])).mockReturnValueOnce(mockStreamTextResult(["ok"]));
    const user = await authedUser();
    const res = await POST(jsonRequest("/api/compose", "POST", { mode: "rewrite", text: "hi there", scene: "chat" }, user.authHeader));
    expect(res.headers.get("x-prosio-model")).toBe("test/custom-fallback");
  });
});
