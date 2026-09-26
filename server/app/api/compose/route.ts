import { createTextStreamResponse, streamText } from "ai";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { gateway } from "@/lib/gateway";
import {
  buildAskPrompt,
  buildEditPrompt,
  buildRewritePrompt,
  buildTranslatePrompt,
  sanitizeComposeOutput,
  type ComposeMode,
  type ComposePrompt,
} from "@/lib/prompts";
import { getStore } from "@/lib/store";
import { RequestTimer } from "@/lib/timing";

// Node runtime; maxDuration covers ask's 45s cap (the larger of the two —
// non-ask uses its own 15s AbortController). Module-scope `gateway` import
// (lib/gateway.ts) reuses the same long-keep-alive HTTP agent as
// /api/transcribe and /api/route.
export const runtime = "nodejs";
export const maxDuration = 45;
export const dynamic = "force-dynamic";

const NON_ASK_TIMEOUT_MS = 15_000;
const ASK_TIMEOUT_MS = 45_000;

// Chosen by the live model-selection eval (scripts/compose-eval.ts,
// eval/compose-cases.json) — see server/README.md's Compose section for
// the results table. Either can be overridden per-deployment via env.
const DEFAULT_COMPOSE_MODEL = "anthropic/claude-haiku-4.5";
const DEFAULT_ASK_MODEL = "anthropic/claude-haiku-4.5";

const appSchema = z
  .object({
    bundleID: z.string().nullable().optional(),
    appName: z.string().nullable().optional(),
    windowTitle: z.string().nullable().optional(),
    url: z.string().nullable().optional(),
  })
  .nullable()
  .optional();

const historyTurnSchema = z.object({
  role: z.enum(["user", "assistant"]),
  text: z.string(),
});

const bodySchema = z
  .object({
    mode: z.enum(["rewrite", "translate", "edit", "ask"]),
    text: z.string().min(1).max(8000),
    selection: z.string().max(20000).nullable().optional(),
    scene: z.enum(["general", "email", "chat", "code", "document"]).default("general"),
    targetLanguage: z.string().nullable().optional(),
    app: appSchema,
    vocabulary: z.array(z.string()).default([]),
    history: z.array(historyTurnSchema).max(20).default([]),
  })
  .superRefine((data, ctx) => {
    if (data.mode === "edit" && !data.selection) {
      ctx.addIssue({ code: "custom", message: "selection is required for edit mode", path: ["selection"] });
    }
    if (data.mode === "translate" && !data.targetLanguage) {
      ctx.addIssue({ code: "custom", message: "targetLanguage is required for translate mode", path: ["targetLanguage"] });
    }
  });

function modelIdFor(mode: ComposeMode): string {
  if (mode === "ask") {
    return process.env.PROSIO_ASK_MODEL || process.env.PROSIO_COMPOSE_MODEL || DEFAULT_ASK_MODEL;
  }
  return process.env.PROSIO_COMPOSE_MODEL || DEFAULT_COMPOSE_MODEL;
}

function buildPrompt(body: z.infer<typeof bodySchema>): ComposePrompt {
  switch (body.mode) {
    case "rewrite":
      return buildRewritePrompt({ transcript: body.text, scene: body.scene, app: body.app, vocabulary: body.vocabulary });
    case "translate":
      return buildTranslatePrompt({
        transcript: body.text,
        // Validated non-null by superRefine above when mode === "translate".
        targetLanguage: body.targetLanguage!,
        scene: body.scene,
        app: body.app,
        vocabulary: body.vocabulary,
      });
    case "edit":
      // Validated non-null by superRefine above when mode === "edit".
      return buildEditPrompt({ selection: body.selection!, instruction: body.text, vocabulary: body.vocabulary });
    case "ask":
      return buildAskPrompt({ question: body.text, app: body.app, selection: body.selection, history: body.history });
  }
}

export const POST = withErrorHandling(async (req: Request) => {
  const timer = new RequestTimer();

  const user = await requireUser(req);
  timer.mark("auth");

  const json = await req.json().catch(() => null);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid request body");
  }
  const body = parsed.data;

  // Same quota gate as POST /api/transcribe (docs/API.md lists 402 among
  // compose's errors) — there's no separate "compose credits" concept yet,
  // so this reuses the monthly audio-seconds entitlement as a blanket
  // over-quota gate.
  const store = getStore();
  const entitlement = await getEntitlement(user.id);
  const { periodStart, periodEnd } = currentBillingPeriod();
  const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);
  if (audioSecondsUsed >= entitlement.audioSecondsLimit) {
    throw new ApiError("quota_exceeded", "Monthly quota exhausted");
  }

  const prompt = buildPrompt(body);
  timer.mark("prompt");

  const modelId = modelIdFor(body.mode);
  const isAsk = body.mode === "ask";
  const temperature = isAsk ? 0.4 : 0.2;
  const timeoutMs = isAsk ? ASK_TIMEOUT_MS : NON_ASK_TIMEOUT_MS;

  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), timeoutMs);

  const result = streamText({
    model: gateway(modelId),
    system: prompt.system,
    messages: prompt.messages,
    temperature,
    abortSignal: abortController.signal,
  });

  if (isAsk) {
    // Stream live. Headers must go out before we know ttft/total, so the
    // Server-Timing header here only carries auth+prompt — the full
    // breakdown (incl. ttft) is still logged server-side once the stream
    // finishes, for observability.
    const headers = {
      "Server-Timing": timer.toServerTimingHeader({ includeTotal: false }),
      "X-Prosio-Model": modelId,
    };

    void (async () => {
      try {
        await result.text; // resolves once the stream finishes (or rejects on failure)
        timer.mark("stream");
      } catch {
        // Mid-stream failures are the client's problem too (truncated body,
        // per docs/API.md) — nothing more to do server-side.
      } finally {
        clearTimeout(timeout);
        console.log("[compose]", { mode: body.mode, model: modelId, ...timer.toObject() });
      }
    })();

    return createTextStreamResponse({ stream: result.textStream, headers });
  }

  // Non-ask: buffer (these outputs are short), sanitize, send as one body —
  // sanitation needs the complete text (docs/PROMPTS.md: strip a wrapping
  // quote pair or code fence, trim).
  let firstChunkAt: number | null = null;
  let full = "";
  try {
    for await (const chunk of result.textStream) {
      if (firstChunkAt === null) {
        firstChunkAt = performance.now();
        timer.mark("ttft");
      }
      full += chunk;
    }
  } catch (err) {
    clearTimeout(timeout);
    const message = err instanceof Error ? err.message : "Gateway request failed";
    throw new ApiError("upstream_error", `Compose failed: ${message}`);
  }
  clearTimeout(timeout);
  if (firstChunkAt === null) timer.mark("ttft"); // empty stream: still record the stage, dur=0

  const sanitized = sanitizeComposeOutput(full);
  timer.mark("sanitize");

  console.log("[compose]", { mode: body.mode, model: modelId, ...timer.toObject() });

  return new Response(sanitized, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "Server-Timing": timer.toServerTimingHeader(),
      "X-Prosio-Model": modelId,
    },
  });
});
