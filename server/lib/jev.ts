import { experimental_evaluate as evaluate, type Experimental_EvaluationQuestion as EvaluationQuestion } from "ai";
// `Experimental_EvaluationModelV4Input` isn't re-exported from "ai" itself
// (only the question/result types are) — it's a transitive dependency of
// `ai`, already present in node_modules, so importing its type directly
// from `@ai-sdk/provider` is safe (type-only, erased at build time).
import type { Experimental_EvaluationModelV4Input as EvaluationInput } from "@ai-sdk/provider";
import { gateway } from "./gateway";

// --- Shared Jev call machinery (P1.2 refactor) ------------------------------
//
// `typesafe-ai/jev` ("System One": typed questions against a shared state,
// answered with typed values + probabilities, ~70-500ms) backs three call
// sites: `lib/router.ts` (POST /api/route), `lib/intent.ts` (POST
// /api/intent), and `lib/transcribe-routing.ts` (POST /api/transcribe's
// combined local-transcript check, which asks the router's and the intent
// classifier's questions in ONE call). All three now go through `callJev`
// below, which owns the actual `evaluate()` call plus the circuit breaker,
// so there's exactly one place that decides "is Jev worth calling right
// now" for the whole server.
//
// === Call shape: confirmed vs inferred === (moved here from lib/router.ts,
// which is where this was originally confirmed — see git history for the
// full investigation notes)
// CONFIRMED by reading the installed `ai`/`@ai-sdk/gateway` type
// definitions: `gateway.evaluationModel("typesafe-ai/jev")` returns an
// `Experimental_EvaluationModelV4`; `evaluate({ model, state, questions })`
// is the generic entry point (`state` is a shared JSON value, `questions`
// a map of question-id -> `{type:"boolean"|"choice"|"score", ...}`,
// answered with one typed answer per question). No Jev-specific
// `providerOptions` exist — it's driven entirely by this generic protocol.
// INFERRED (no web access to TypeSafe's own docs in this environment):
// their "Noul (probability a statement is true)" concept maps to the SDK's
// generic `"boolean"` question type.

export const JEV_MODEL = "typesafe-ai/jev";

// --- Circuit breaker ---------------------------------------------------
//
// Coordinator follow-up (2026-09-26, originally added for lib/intent.ts
// only): while Jev is down (e.g. a `GatewayRateLimitError` "high demand"
// condition), every call was paying its full timeout for a request that
// was always going to fail. After a failure/timeout, skip Jev entirely for
// a cooldown window and return "unavailable" immediately; then let exactly
// one request through as a probe to check whether Jev has recovered.
//
// Generalized here (P1.2) to cover every Jev call site, not just intent
// classification — a single shared breaker means a Jev outage is detected
// once and every caller (router, intent, and the new combined
// route+intent check) benefits immediately, instead of each maintaining
// its own independent (and independently-failing) breaker.
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
  console.log(`[jev] circuit breaker: ${from} -> ${to}`);
}

/**
 * Whether a Jev call should be skipped, returning "unavailable" (or
 * equivalent) immediately. Has the side effect of transitioning
 * "open" -> "half-open" (and letting that one call through as the probe)
 * once the cooldown has elapsed — this mutation is synchronous, so there's
 * no race with other calls checking the same state before any `await` runs.
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

/** Test-only: resets the shared circuit breaker to "closed". */
export function resetJevCircuitBreakerForTests(): void {
  breakerState = "closed";
  breakerOpenedAt = 0;
}

// --- Shared answer-shape guards -----------------------------------------

export function isBooleanAnswer(value: unknown): value is { type: "boolean"; probability: number } {
  return (
    typeof value === "object" &&
    value !== null &&
    (value as { type?: unknown }).type === "boolean" &&
    typeof (value as { probability?: unknown }).probability === "number"
  );
}

export function isChoiceAnswer(
  value: unknown
): value is { type: "choice"; choice: string; probabilities?: Record<string, number> } {
  return typeof value === "object" && value !== null && (value as { type?: unknown }).type === "choice";
}

// --- The shared call ------------------------------------------------------

export interface CallJevParams<QUESTIONS extends Record<string, EvaluationQuestion>, TResult> {
  state: EvaluationInput;
  questions: QUESTIONS;
  timeoutMs: number;
  /**
   * Validates and extracts the caller's expected shape from the raw
   * result. MUST throw for any unexpected/unoffered answer — that's
   * treated exactly like a network failure (never trust upstream blindly),
   * both for the caller's own error handling and for the circuit breaker
   * (a structurally-invalid answer opens the breaker, same as a timeout).
   */
  parse: (result: { answers: Record<string, unknown> }) => TResult;
}

/**
 * Calls Jev with the shared circuit breaker applied. Returns `null` when
 * the breaker is open/half-open-and-busy, when the call errors or times
 * out, or when `parse` throws (unexpected answer shape) — callers map
 * `null` to their own "Jev unavailable" response, exactly as if the call
 * itself had failed. Never throws.
 */
export async function callJev<QUESTIONS extends Record<string, EvaluationQuestion>, TResult>(
  params: CallJevParams<QUESTIONS, TResult>
): Promise<TResult | null> {
  if (shouldSkipJev()) {
    return null;
  }

  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), params.timeoutMs);

  try {
    const result = await evaluate({
      model: gateway.evaluationModel(JEV_MODEL),
      state: params.state,
      questions: params.questions,
      abortSignal: abortController.signal,
    });

    const parsed = params.parse(result);
    recordJevSuccess();
    return parsed;
  } catch {
    recordJevFailure();
    return null;
  } finally {
    clearTimeout(timeout);
  }
}
