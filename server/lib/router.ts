import { experimental_evaluate as evaluate } from "ai";
import { gateway } from "./gateway";

// --- Routing (auto mode) — see docs/API.md § Routing (auto mode) ----------
//
// Decides whether an on-device transcript can be inserted as-is, skipping
// the cloud SMART pass (POST /api/transcribe), using Gateway model
// `typesafe-ai/jev` — TypeSafe's "System One" decision model: typed
// questions against a shared state, answered with typed values +
// probabilities, in ~70-500ms.
//
// === Call shape: confirmed vs inferred ===
// CONFIRMED by reading node_modules/@ai-sdk/gateway's and
// node_modules/@ai-sdk/provider's installed type definitions (ai@7.0.114,
// @ai-sdk/gateway@4.0.92 — the evaluate API is already present in both;
// no upgrade needed):
//   - `gateway.evaluationModel("typesafe-ai/jev")` returns an
//     `Experimental_EvaluationModelV4` (GatewayEvaluationModelId includes
//     `'typesafe-ai/jev'` by name).
//   - `evaluate({ model, state, questions })` from `ai` is the generic
//     entry point: `state` is `string | JSONObject | JSONValue[]` (one
//     shared value every question is judged against); `questions` is a map
//     of question-id -> question, each either `{type:"choice", criteria}`,
//     `{type:"score", criteria}`, or `{type:"boolean"}`; the result is
//     `{ answers: { [id]: answer } }` with one answer per question,
//     `{type:"boolean", probability: number}` for boolean questions.
//   - No Jev-specific `providerOptions` exist in the SDK's types — the
//     model is driven entirely through the generic question/state protocol
//     above, nothing vendor-specific to configure.
// INFERRED (not from TypeSafe's own docs — no web access in this
// environment): the task's "Noul (probability a statement is true)" is
// TypeSafe/Jev's own name for exactly what the AI SDK's generic protocol
// calls a `"boolean"` question (a statement + P(true)) — the shapes line up
// exactly (a statement in, a single probability out), so this mapping is
// used with high confidence, but isn't confirmed against TypeSafe's own
// documentation.

export const ROUTER_MODEL = "typesafe-ai/jev";
export const CLEAN_THRESHOLD = 0.8;
export const ROUTER_TIMEOUT_MS = 1500;

export type RouteReason = "clean" | "needs-cleanup" | "likely-misrecognized" | "router-error";

export interface RouteParams {
  transcript: string;
  vocabulary: string[];
  languageHints: string[];
}

export interface RouteDecision {
  needsCloud: boolean;
  cleanProbability: number | null;
  reason: RouteReason;
  latencyMs: number;
}

// Primary question: drives cleanProbability and the needsCloud gate.
const CLEAN_QUESTION_INSTRUCTIONS =
  "This dictated transcript can be inserted exactly as-is: it has no filler words or " +
  "hesitations, no self-corrections or restarts, no spoken list that should be " +
  "formatted, correct punctuation, and no apparent speech-recognition errors (such as " +
  "garbled mixed Chinese/English words or misheard names/terms from the vocabulary).";

// Secondary question: only used (when the transcript isn't clean) to pick
// between the two failure reasons docs/API.md defines. Keeping this
// narrowly scoped to recognition errors specifically (rather than restating
// the whole primary question) is what makes it useful as a tie-breaker.
const RECOGNITION_QUESTION_INSTRUCTIONS =
  "This transcript's words were all recognized correctly: no garbled or nonsensical " +
  "mixed Chinese/English word combinations, and no misheard names or terms that should " +
  "have matched the personal dictionary vocabulary provided in state.";

function isBooleanAnswer(answer: unknown): answer is { type: "boolean"; probability: number } {
  return (
    typeof answer === "object" &&
    answer !== null &&
    (answer as { type?: unknown }).type === "boolean" &&
    typeof (answer as { probability?: unknown }).probability === "number"
  );
}

/**
 * Asks Jev whether `params.transcript` can be inserted as-is. Never throws:
 * any error, unexpected answer shape, or a call taking longer than
 * `timeoutMs` (default 1.5s, per docs/API.md) resolves to
 * `{ needsCloud: true, reason: "router-error" }` — routing failures must
 * never block dictation.
 */
export async function routeTranscript(params: RouteParams, timeoutMs = ROUTER_TIMEOUT_MS): Promise<RouteDecision> {
  const startedAt = performance.now();
  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), timeoutMs);

  try {
    const result = await evaluate({
      model: gateway.evaluationModel(ROUTER_MODEL),
      state: {
        transcript: params.transcript,
        languageHints: params.languageHints,
        vocabulary: params.vocabulary,
      },
      questions: {
        clean: { type: "boolean", instructions: CLEAN_QUESTION_INSTRUCTIONS },
        recognized: { type: "boolean", instructions: RECOGNITION_QUESTION_INSTRUCTIONS },
      },
      abortSignal: abortController.signal,
    });

    const cleanAnswer = result.answers.clean;
    const recognizedAnswer = result.answers.recognized;
    if (!isBooleanAnswer(cleanAnswer) || !isBooleanAnswer(recognizedAnswer)) {
      throw new Error("Unexpected Jev answer shape (expected boolean answers)");
    }

    const cleanProbability = cleanAnswer.probability;
    const needsCloud = !(cleanProbability >= CLEAN_THRESHOLD);
    const reason: RouteReason = !needsCloud
      ? "clean"
      : recognizedAnswer.probability < CLEAN_THRESHOLD
        ? "likely-misrecognized"
        : "needs-cleanup";

    return { needsCloud, cleanProbability, reason, latencyMs: Math.round(performance.now() - startedAt) };
  } catch {
    return {
      needsCloud: true,
      cleanProbability: null,
      reason: "router-error",
      latencyMs: Math.round(performance.now() - startedAt),
    };
  } finally {
    clearTimeout(timeout);
  }
}
