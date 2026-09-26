import { callJev, isChoiceAnswer } from "./jev";

// --- Intent classification (auto mode) — see docs/PROMPTS.md §5b ---------
//
// Decides which mode a finished dictation is: dictate (type it as-is),
// edit (apply it to the current selection), ask (answer it), or translate
// (translate the spoken content). Uses Gateway model `typesafe-ai/jev` via
// `lib/jev.ts`'s shared `callJev` (evaluate() call + circuit breaker) — see
// that file's header for the confirmed vs. inferred call-shape notes.
//
// Per the user's amendment (2026-09-26): when Jev errors or exceeds the
// timeout, the SERVER DOES NOT fall back to an LLM. It reports
// `{ intent: null, source: "unavailable" }`, and the CLIENT applies
// bilingual (zh/en) rules (`IntentRules` in ProsioCore, Swift — the source
// of truth for those rules is docs/PROMPTS.md §5b, not this file). A TS
// port of those same rules exists only for eval comparison, in
// scripts/intent-rules.ts — clearly marked as non-authoritative there.
//
// P1.2: `lib/transcribe-routing.ts`'s combined local-transcript check asks
// this same intent question (reusing the constants exported below)
// alongside the router's two questions, in one Jev call.

export const INTENT_MODEL = "typesafe-ai/jev";
export const INTENT_CONFIDENCE_THRESHOLD = 0.7;
export const INTENT_TIMEOUT_MS = 1200;

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

export function defaultIntent(hasSelection: boolean): IntentValue {
  return hasSelection ? "edit" : "dictate";
}

export const CLASSIFIER_INSTRUCTIONS =
  "The utterance was spoken into Prosio, a voice keyboard. Normally it is text the user wants typed into the current app, even when it is a question or request meant for someone else. Decide what the user wants Prosio to do.";

export const ASK_CRITERION =
  "The user addresses Prosio itself and wants an answer or help shown to them, not typed — for example asking a factual question, asking how to do something, or asking about the selected text.";
export const TRANSLATE_CRITERION =
  "The user explicitly asks Prosio to translate spoken content into another language (not when translation is merely mentioned in the text).";
export const DICTATE_CRITERION = "Type the utterance as text. This includes questions, requests and messages written for other people.";
export const EDIT_CRITERION = "Change the selected text as the utterance instructs.";

/** The criteria offered to Jev for a given `hasSelection` — shared with `lib/transcribe-routing.ts`. */
export function intentCriteriaFor(hasSelection: boolean): Record<string, string> {
  return hasSelection
    ? { edit: EDIT_CRITERION, ask: ASK_CRITERION, translate: TRANSLATE_CRITERION }
    : { dictate: DICTATE_CRITERION, ask: ASK_CRITERION, translate: TRANSLATE_CRITERION };
}

/**
 * Applies docs/PROMPTS.md §5b's threshold policy to a raw Jev choice
 * answer. Shared with `lib/transcribe-routing.ts`.
 */
export function decideIntent(
  choice: string,
  confidence: number | null,
  hasSelection: boolean
): { intent: IntentValue; confidence: number | null } {
  if (confidence !== null && confidence >= INTENT_CONFIDENCE_THRESHOLD) {
    return { intent: choice as IntentValue, confidence };
  }
  return { intent: defaultIntent(hasSelection), confidence };
}

/**
 * Classifies a dictation's intent via Jev. Never throws: any error, an
 * unexpected answer shape, a breaker skip, or a call taking longer than
 * `INTENT_TIMEOUT_MS` (1.2s, per docs/PROMPTS.md) resolves to
 * `{ intent: null, source: "unavailable" }` — the caller (client) is
 * responsible for the rules-based fallback in that case, not this function.
 */
export async function classifyIntent(params: IntentParams): Promise<IntentDecision> {
  const startedAt = performance.now();
  const criteria = intentCriteriaFor(params.hasSelection);

  const parsed = await callJev({
    state: { utterance: params.transcript, hasSelection: params.hasSelection, app: params.appName ?? null },
    questions: {
      intent: { type: "choice", instructions: CLASSIFIER_INSTRUCTIONS, criteria },
    },
    timeoutMs: INTENT_TIMEOUT_MS,
    parse: (result) => {
      const answer = result.answers.intent;
      if (!isChoiceAnswer(answer)) {
        throw new Error("Unexpected Jev answer shape (expected a choice answer)");
      }
      if (!(answer.choice in criteria)) {
        // Never trust upstream blindly: Jev returned something we didn't offer.
        throw new Error(`Jev returned an unoffered choice: ${answer.choice}`);
      }
      return { choice: answer.choice, confidence: answer.probabilities?.[answer.choice] ?? null };
    },
  });

  const latencyMs = Math.round(performance.now() - startedAt);
  if (parsed === null) {
    return { intent: null, confidence: null, source: "unavailable", latencyMs };
  }

  const { intent, confidence } = decideIntent(parsed.choice, parsed.confidence, params.hasSelection);
  return { intent, confidence, source: "jev", latencyMs };
}
