import { experimental_evaluate as evaluate } from "ai";
import { gateway } from "./gateway";

// --- Intent classification (auto mode) — see docs/PROMPTS.md §5b ---------
//
// Decides which mode a finished dictation is: dictate (type it as-is),
// edit (apply it to the current selection), ask (answer it), or translate
// (translate the spoken content). Uses Gateway model `typesafe-ai/jev` via
// the same generic `evaluate()` choice-question protocol as
// `lib/router.ts` — see that file's header comment for the confirmed vs.
// inferred call-shape notes; this reuses the identical confirmed shape.
//
// Per the user's amendment (2026-09-26): when Jev errors or exceeds the
// timeout, the SERVER DOES NOT fall back to an LLM. It reports
// `{ intent: null, source: "unavailable" }`, and the CLIENT applies
// bilingual (zh/en) rules (`IntentRules` in ProsioCore, Swift — the source
// of truth for those rules is docs/PROMPTS.md §5b, not this file). A TS
// port of those same rules exists only for eval comparison, in
// scripts/intent-rules.ts — clearly marked as non-authoritative there.

export const INTENT_MODEL = "typesafe-ai/jev";
export const INTENT_CONFIDENCE_THRESHOLD = 0.7;
export const INTENT_TIMEOUT_MS = 1200;

// --- Circuit breaker ---------------------------------------------------
//
// Coordinator follow-up (2026-09-26): while Jev is down (e.g. the current
// GatewayRateLimitError "high demand" condition), every single dictation
// was paying the full 1200ms timeout for a call that was always going to
// fail. After a failure/timeout, skip Jev entirely for a cooldown window
// and return "unavailable" immediately; then let exactly one request
// through as a probe to check whether Jev has recovered.
//
// States: "closed" (normal — call Jev), "open" (skip Jev, return
// unavailable immediately), "half-open" (cooldown elapsed — exactly one
// in-flight request is allowed through as a probe; concurrent requests
// arriving while that probe is in flight are also skipped, since JS's
// synchronous state transition happens before any `await`).
export const BREAKER_COOLDOWN_MS = 60_000;

type BreakerState = "closed" | "open" | "half-open";

let breakerState: BreakerState = "closed";
let breakerOpenedAt = 0;

function logBreakerTransition(from: BreakerState, to: BreakerState): void {
  console.log(`[intent] circuit breaker: ${from} -> ${to}`);
}

/**
 * Whether classifyIntent should skip calling Jev and return "unavailable"
 * immediately. Has the side effect of transitioning "open" -> "half-open"
 * (and letting that one call through as the probe) once the cooldown has
 * elapsed — this mutation is synchronous, so there's no race with other
 * calls checking the same state before any `await` runs.
 */
function shouldSkipJev(): boolean {
  if (breakerState === "closed") return false;
  if (breakerState === "open") {
    if (Date.now() - breakerOpenedAt >= BREAKER_COOLDOWN_MS) {
      breakerState = "half-open";
      logBreakerTransition("open", "half-open");
      return false; // let this call through as the probe
    }
    return true; // still cooling down
  }
  // half-open: a probe is already in flight; skip until it resolves.
  return true;
}

function recordJevSuccess(): void {
  if (breakerState !== "closed") {
    logBreakerTransition(breakerState, "closed");
    breakerState = "closed";
  }
}

function recordJevFailure(): void {
  const from = breakerState;
  breakerState = "open";
  breakerOpenedAt = Date.now();
  if (from !== "open") {
    logBreakerTransition(from, "open");
  }
}

/** Test-only: resets the circuit breaker to "closed". */
export function resetIntentCircuitBreakerForTests(): void {
  breakerState = "closed";
  breakerOpenedAt = 0;
}

export type IntentValue = "dictate" | "edit" | "ask" | "translate";
export type IntentSource = "jev" | "unavailable";

export interface IntentDecision {
  intent: IntentValue | null;
  confidence: number | null;
  source: IntentSource;
  latencyMs: number;
}

export interface IntentParams {
  transcript: string;
  hasSelection: boolean;
  /** Just the app name (docs/PROMPTS.md §5b's state is `{ utterance, hasSelection, app: appName }`), not a full app context object. */
  appName?: string | null;
}

function defaultIntent(hasSelection: boolean): IntentValue {
  return hasSelection ? "edit" : "dictate";
}

const CLASSIFIER_INSTRUCTIONS =
  "The utterance was spoken into Prosio, a voice keyboard. Normally it is text the user wants typed into the current app, even when it is a question or request meant for someone else. Decide what the user wants Prosio to do.";

const ASK_CRITERION =
  "The user addresses Prosio itself and wants an answer or help shown to them, not typed — for example asking a factual question, asking how to do something, or asking about the selected text.";
const TRANSLATE_CRITERION =
  "The user explicitly asks Prosio to translate spoken content into another language (not when translation is merely mentioned in the text).";
const DICTATE_CRITERION = "Type the utterance as text. This includes questions, requests and messages written for other people.";
const EDIT_CRITERION = "Change the selected text as the utterance instructs.";

function isChoiceAnswer(value: unknown): value is { type: "choice"; choice: string; probabilities?: Record<string, number> } {
  return typeof value === "object" && value !== null && (value as { type?: unknown }).type === "choice";
}

/**
 * Classifies a dictation's intent via Jev. Never throws: any error, an
 * unexpected answer shape, or a call taking longer than `INTENT_TIMEOUT_MS`
 * (1.2s, per docs/PROMPTS.md) resolves to `{ intent: null, source:
 * "unavailable" }` — the caller (client) is responsible for the
 * rules-based fallback in that case, not this function.
 */
export async function classifyIntent(params: IntentParams): Promise<IntentDecision> {
  const startedAt = performance.now();

  if (shouldSkipJev()) {
    return { intent: null, confidence: null, source: "unavailable", latencyMs: Math.round(performance.now() - startedAt) };
  }

  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), INTENT_TIMEOUT_MS);

  try {
    // Only offer the criterion that matches hasSelection, per docs/PROMPTS.md §5b.
    const criteria: Record<string, string> = params.hasSelection
      ? { edit: EDIT_CRITERION, ask: ASK_CRITERION, translate: TRANSLATE_CRITERION }
      : { dictate: DICTATE_CRITERION, ask: ASK_CRITERION, translate: TRANSLATE_CRITERION };

    const result = await evaluate({
      model: gateway.evaluationModel(INTENT_MODEL),
      state: { utterance: params.transcript, hasSelection: params.hasSelection, app: params.appName ?? null },
      questions: {
        intent: { type: "choice", instructions: CLASSIFIER_INSTRUCTIONS, criteria },
      },
      abortSignal: abortController.signal,
    });

    const answer = result.answers.intent;
    if (!isChoiceAnswer(answer)) {
      throw new Error("Unexpected Jev answer shape (expected a choice answer)");
    }
    if (!(answer.choice in criteria)) {
      // Never trust upstream blindly: Jev returned something we didn't offer.
      throw new Error(`Jev returned an unoffered choice: ${answer.choice}`);
    }

    const confidence = answer.probabilities?.[answer.choice] ?? null;
    const latencyMs = Math.round(performance.now() - startedAt);

    // Jev answered (whether or not it met the confidence threshold) —
    // that's a success for the circuit breaker's purposes.
    recordJevSuccess();

    if (confidence !== null && confidence >= INTENT_CONFIDENCE_THRESHOLD) {
      return { intent: answer.choice as IntentValue, confidence, source: "jev", latencyMs };
    }
    // Below threshold (or no probability distribution at all): Jev did
    // answer, so source is still "jev" — we just use the default rather
    // than an unconfident guess. `confidence` still reports whatever Jev
    // returned, for calibration (scripts/intent-eval.ts's threshold sweep).
    return { intent: defaultIntent(params.hasSelection), confidence, source: "jev", latencyMs };
  } catch {
    recordJevFailure();
    return { intent: null, confidence: null, source: "unavailable", latencyMs: Math.round(performance.now() - startedAt) };
  } finally {
    clearTimeout(timeout);
  }
}
