import { createTextStreamResponse, streamText } from "ai";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { gateway } from "@/lib/gateway";
import { callOptionsFor, DEFAULT_COMPOSE_MODEL } from "@/lib/model-options";
import {
  buildAskPrompt,
  buildEditPrompt,
  buildRewritePrompt,
  buildTranslateCommandPrompt,
  buildTranslatePrompt,
  sanitizeComposeOutput,
  type ComposeMode,
  type ComposePrompt,
} from "@/lib/prompts";
import { getStore } from "@/lib/store";
import { RequestTimer } from "@/lib/timing";

// Node runtime; maxDuration covers ask's 45s cap (the larger of the two —
// non-ask uses its own 15s AbortController, up to 2x if a fallback retry
// fires). Module-scope `gateway` import (lib/gateway.ts) reuses the same
// long-keep-alive HTTP agent as /api/transcribe and /api/route.
export const runtime = "nodejs";
export const maxDuration = 45;
export const dynamic = "force-dynamic";

const NON_ASK_TIMEOUT_MS = 15_000;
const ASK_TIMEOUT_MS = 45_000;

// DEFAULT_COMPOSE_MODEL, its per-model call-option capabilities
// (temperature/reasoningEffort), and callOptionsFor() now live in
// lib/model-options.ts, shared with the P1.2.1 list-repair step in
// POST /api/transcribe (lib/list-repair.ts) — see that file for the full
// history/reasoning (2026-09-26 model bake-off, live-tested capabilities).
const DEFAULT_ASK_MODEL = "openai/gpt-6-luna";

// Retried into when luna's output trips a guardrail (see runNonAsk below).
const DEFAULT_FALLBACK_MODEL = "openai/gpt-5.4-mini";

// translateCommand's target language is optional (docs/PROMPTS.md §2b) —
// falls back to this when the client doesn't send one.
const DEFAULT_TRANSLATE_COMMAND_LANGUAGE = "en-US";

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
    mode: z.enum(["rewrite", "translate", "translateCommand", "edit", "ask"]),
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
type ComposeBody = z.infer<typeof bodySchema>;

function modelIdFor(mode: ComposeMode): string {
  if (mode === "ask") {
    return process.env.PROSIO_ASK_MODEL || process.env.PROSIO_COMPOSE_MODEL || DEFAULT_ASK_MODEL;
  }
  return process.env.PROSIO_COMPOSE_MODEL || DEFAULT_COMPOSE_MODEL;
}

function fallbackModelId(): string {
  return process.env.PROSIO_COMPOSE_FALLBACK_MODEL || DEFAULT_FALLBACK_MODEL;
}

function buildPrompt(body: ComposeBody): ComposePrompt {
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
    case "translateCommand":
      return buildTranslateCommandPrompt({
        transcript: body.text,
        defaultLanguage: body.targetLanguage ?? DEFAULT_TRANSLATE_COMMAND_LANGUAGE,
        vocabulary: body.vocabulary,
      });
    case "edit":
      // Validated non-null by superRefine above when mode === "edit".
      return buildEditPrompt({ selection: body.selection!, instruction: body.text, vocabulary: body.vocabulary });
    case "ask":
      return buildAskPrompt({ question: body.text, app: body.app, selection: body.selection, history: body.history });
  }
}

/** The text a guardrail falls back to returning unchanged, per mode. */
function originalInputFor(body: ComposeBody): string {
  return body.mode === "edit" ? body.selection! : body.text;
}

function isBlank(text: string): boolean {
  return text.trim().length === 0;
}

// --- Edit drift guard --------------------------------------------------
//
// Observed live (scripts/compose-bakeoff.ts, `ed-cant-apply`): asked to
// "add a bar chart" to plain text — something no text edit can literally
// do — gpt-6-luna fabricated ASCII/box-drawing "chart" art 3/3 times
// instead of following PROMPTS.md's "return the selection unchanged"
// fallback rule. This guard catches that class of drift generically.

const ART_OR_FENCE_RE = /```|[─-▟]|[+\-]{3,}|\|.*\|.*\|/;
const EXPANSION_REQUESTED_RE = /\b(expand|elaborate|add (a|an|another|more|some))\b|扩写|补充|扩展/i;

function hasArtOrFence(text: string): boolean {
  return ART_OR_FENCE_RE.test(text);
}

/** Edit-mode only: true if the output looks like it drifted into fabricated content rather than a text edit. */
function editDriftDetected(output: string, selection: string, instruction: string): boolean {
  const introducedArt = hasArtOrFence(output) && !hasArtOrFence(selection);
  const expansionRequested = EXPANSION_REQUESTED_RE.test(instruction);
  // The >=20-char floor avoids false positives on very short selections
  // (e.g. selection "No." — almost any real edit is "3x longer" than 3
  // characters; that's normal politeness padding, not fabricated drift).
  const tooLong = !expansionRequested && selection.length >= 20 && output.length > selection.length * 3;
  return introducedArt || tooLong;
}

// --- non-ask generation (buffered + sanitized) --------------------------

interface NonAskResult {
  text: string;
  error?: string;
}

async function runNonAsk(modelId: string, mode: ComposeMode, prompt: ComposePrompt, temperature: number): Promise<NonAskResult> {
  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), NON_ASK_TIMEOUT_MS);
  try {
    const result = streamText({
      model: gateway(modelId),
      system: prompt.system,
      messages: prompt.messages,
      abortSignal: abortController.signal,
      ...callOptionsFor(modelId, temperature),
    });
    let full = "";
    for await (const chunk of result.textStream) full += chunk;
    return { text: sanitizeComposeOutput(full) };
  } catch (err) {
    return { text: "", error: err instanceof Error ? err.message : String(err) };
  } finally {
    clearTimeout(timeout);
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

  if (isAsk) {
    const abortController = new AbortController();
    const timeout = setTimeout(() => abortController.abort(), ASK_TIMEOUT_MS);

    const result = streamText({
      model: gateway(modelId),
      system: prompt.system,
      messages: prompt.messages,
      abortSignal: abortController.signal,
      ...callOptionsFor(modelId, temperature),
    });

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
        const finalText = await result.text; // resolves once the stream finishes (or rejects on failure)
        timer.mark("stream");
        if (isBlank(finalText)) {
          // No guard/retry for ask (it's already streamed to the client) —
          // the client shows "empty answer"; just log it server-side.
          console.warn("[compose] ask produced empty output", { model: modelId });
        }
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
  // quote pair or code fence, trim). Apply guardrails for the primary
  // model's observed failure modes (empty output; edit-mode content drift),
  // retrying once with a fallback model before giving up.
  let usedModelId = modelId;
  let fallbackReason: "empty" | "drift" | null = null;

  let outcome = await runNonAsk(modelId, body.mode, prompt, temperature);
  if (outcome.error) {
    throw new ApiError("upstream_error", `Compose failed: ${outcome.error}`);
  }
  timer.mark("ttft"); // first attempt's generation, buffered (no true TTFT available here)

  const isDrift = body.mode === "edit" && !isBlank(outcome.text) && editDriftDetected(outcome.text, body.selection!, body.text);

  if (isBlank(outcome.text) || isDrift) {
    const fbModel = fallbackModelId();
    const retry = await runNonAsk(fbModel, body.mode, prompt, temperature);
    timer.mark("fallback");

    const retryStillBad =
      retry.error !== undefined ||
      isBlank(retry.text) ||
      (body.mode === "edit" && editDriftDetected(retry.text, body.selection!, body.text));

    if (retryStillBad) {
      outcome = { text: originalInputFor(body) };
      usedModelId = fbModel;
      // Report whichever guard triggered the retry in the first place.
      fallbackReason = isDrift ? "drift" : "empty";
    } else {
      outcome = retry;
      usedModelId = fbModel;
    }
  }

  const sanitized = outcome.text;
  timer.mark("sanitize");

  console.log("[compose]", { mode: body.mode, model: usedModelId, fallbackReason, ...timer.toObject() });

  const headers: Record<string, string> = {
    "content-type": "text/plain; charset=utf-8",
    "Server-Timing": timer.toServerTimingHeader(),
    "X-Prosio-Model": usedModelId,
  };
  if (fallbackReason) {
    headers["X-Prosio-Fallback"] = fallbackReason;
  }

  return new Response(sanitized, { headers });
});
