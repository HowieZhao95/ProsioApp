import { callJev, isBooleanAnswer, isChoiceAnswer } from "./jev";
import { CLEAN_QUESTION_INSTRUCTIONS, RECOGNITION_QUESTION_INSTRUCTIONS, decideRoute, type RouteReason } from "./router";
import { CLASSIFIER_INSTRUCTIONS, decideIntent, intentCriteriaFor, type IntentValue } from "./intent";
import { needsFormattingGuard } from "./list-guard";

// --- Combined local-transcript check (P1.2) --------------------------------
//
// docs/P1.2-AUDIO-ROUTING.md §3: `POST /api/transcribe`'s new
// `localTranscript` fast path needs BOTH an answer to "is this clean enough
// to skip Gemini" (lib/router.ts's question pair) AND "what does the user
// want done with it" (lib/intent.ts's §5b question) before it can decide
// whether to skip the cloud call. Rather than two separate Jev round trips
// (which would double the latency this feature exists to avoid), this asks
// all three questions in ONE `evaluate()` call, reusing each module's exact
// question instructions/criteria and decision policy so this never drifts
// from what `/api/route` and `/api/intent` do standalone.
//
// Threshold: this fast path uses its OWN, stricter threshold
// (`LOCAL_TEXT_CLEAN_THRESHOLD = 0.9`) than `/api/route`'s existing
// `CLEAN_THRESHOLD` (0.8, unchanged — still used by lib/router.ts for that
// endpoint). Skipping Gemini entirely is a stronger claim than "route to
// the SMART pass or not" — a false "clean" here means the user's dictation
// is inserted as-is with zero cloud correction, so per
// docs/P1.2-AUDIO-ROUTING.md this starts conservative and is only lowered
// after scripts/route-eval.ts shows ~0 false-clean at a lower threshold.
export const LOCAL_TEXT_CLEAN_THRESHOLD = 0.9;

// Matches lib/router.ts's ROUTER_TIMEOUT_MS — this call is a superset of
// that one (same two questions plus the intent question), so it gets the
// same time budget rather than a shorter one that might not give the
// (very slightly larger) 3-question call enough time to answer everything.
export const LOCAL_CHECK_TIMEOUT_MS = 1500;

export interface LocalCheckParams {
  transcript: string;
  vocabulary: string[];
  languageHints: string[];
  hasSelection: boolean;
  appName?: string | null;
}

export interface LocalCheckDecision {
  needsCloud: boolean;
  cleanProbability: number | null;
  reason: RouteReason;
  intent: IntentValue | null;
  intentConfidence: number | null;
  /** Always "jev" when Jev answered (even if intent defaulted below threshold) or "unavailable" when the whole call failed/timed out/was skipped by the breaker. */
  intentSource: "jev" | "unavailable";
  latencyMs: number;
}

/**
 * Asks Jev, in one call, whether `params.transcript` is clean enough to
 * skip Gemini AND what the user wants done with it. Never throws: any
 * error, unexpected answer shape, breaker skip, or timeout resolves to
 * `{ needsCloud: true, reason: "router-error", intent: null,
 * intentSource: "unavailable" }` — exactly like `routeTranscript`'s and
 * `classifyIntent`'s own failure modes, since a fast-path failure must
 * always fall through to the normal (cloud) path, never block dictation.
 */
export async function checkLocalTranscript(params: LocalCheckParams): Promise<LocalCheckDecision> {
  const startedAt = performance.now();

  // Cheap, Jev-independent guard first (lib/list-guard.ts): an unformatted
  // spoken list must never take the local fast path, even if Jev is wrong
  // or unavailable. Forcing cloud here also skips the Jev call entirely —
  // there's no need to ask a question we already have a confident answer
  // to. Intent is left null/"unavailable"; the caller (app/api/transcribe's
  // route handler) reclassifies on the final text either way, since intent
  // being null is one of its own reclassify triggers.
  if (needsFormattingGuard(params.transcript).triggered) {
    return {
      needsCloud: true,
      cleanProbability: null,
      reason: "needs-formatting",
      intent: null,
      intentConfidence: null,
      intentSource: "unavailable",
      latencyMs: Math.round(performance.now() - startedAt),
    };
  }

  const intentCriteria = intentCriteriaFor(params.hasSelection);

  const parsed = await callJev({
    state: {
      // Both state shapes are included: lib/router.ts's docs/API.md state
      // is `{ transcript, languageHints, vocabulary }`, docs/PROMPTS.md
      // §5b's is `{ utterance, hasSelection, app }`. Rather than pick one
      // key name and silently diverge from the other spec, this combined
      // call satisfies both verbatim, in one shared state object.
      transcript: params.transcript,
      utterance: params.transcript,
      languageHints: params.languageHints,
      vocabulary: params.vocabulary,
      hasSelection: params.hasSelection,
      app: params.appName ?? null,
    },
    questions: {
      clean: { type: "boolean", instructions: CLEAN_QUESTION_INSTRUCTIONS },
      recognized: { type: "boolean", instructions: RECOGNITION_QUESTION_INSTRUCTIONS },
      intent: { type: "choice", instructions: CLASSIFIER_INSTRUCTIONS, criteria: intentCriteria },
    },
    timeoutMs: LOCAL_CHECK_TIMEOUT_MS,
    parse: (result) => {
      const cleanAnswer = result.answers.clean;
      const recognizedAnswer = result.answers.recognized;
      const intentAnswer = result.answers.intent;
      if (!isBooleanAnswer(cleanAnswer) || !isBooleanAnswer(recognizedAnswer)) {
        throw new Error("Unexpected Jev answer shape (expected boolean answers for clean/recognized)");
      }
      if (!isChoiceAnswer(intentAnswer) || !(intentAnswer.choice in intentCriteria)) {
        throw new Error("Unexpected Jev answer shape (expected a choice answer for intent)");
      }
      return {
        cleanProbability: cleanAnswer.probability,
        recognizedProbability: recognizedAnswer.probability,
        intentChoice: intentAnswer.choice,
        intentConfidence: intentAnswer.probabilities?.[intentAnswer.choice] ?? null,
      };
    },
  });

  const latencyMs = Math.round(performance.now() - startedAt);
  if (parsed === null) {
    return {
      needsCloud: true,
      cleanProbability: null,
      reason: "router-error",
      intent: null,
      intentConfidence: null,
      intentSource: "unavailable",
      latencyMs,
    };
  }

  const { needsCloud, reason } = decideRoute(parsed.cleanProbability, parsed.recognizedProbability, LOCAL_TEXT_CLEAN_THRESHOLD);
  const { intent, confidence } = decideIntent(parsed.intentChoice, parsed.intentConfidence, params.hasSelection);

  return {
    needsCloud,
    cleanProbability: parsed.cleanProbability,
    reason,
    intent,
    intentConfidence: confidence,
    intentSource: "jev",
    latencyMs,
  };
}
