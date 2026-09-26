import { callJev, isBooleanAnswer } from "./jev";

// --- Routing (auto mode) — see docs/API.md § Routing (auto mode) ----------
//
// Decides whether an on-device transcript can be inserted as-is, skipping
// the cloud SMART pass (POST /api/transcribe), using Gateway model
// `typesafe-ai/jev`. The actual `evaluate()` call (plus the shared circuit
// breaker) lives in `lib/jev.ts`'s `callJev` — see that file's header for
// the confirmed-vs-inferred call-shape notes; this module only owns the
// router's two questions and its decision policy.
//
// P1.2: `lib/transcribe-routing.ts`'s combined local-transcript check asks
// this same `clean`/`recognized` question pair (reusing the instructions
// exported below) alongside the intent classifier's question, in one Jev
// call — see that file for why they're combined there instead of two
// separate round trips.

export const CLEAN_THRESHOLD = 0.8;
export const ROUTER_TIMEOUT_MS = 1500;

// "no-local-transcript" and "needs-formatting" are only ever produced by
// POST /api/transcribe (lib/transcribe-routing.ts /
// app/api/transcribe/route.ts): the former when the client didn't send a
// `localTranscript` at all (so no route check ran), the latter when
// lib/list-guard.ts's cheap, Jev-independent guard detects an unformatted
// spoken list. POST /api/route always has a localTranscript and never runs
// the list guard, so it never returns either value.
export type RouteReason = "clean" | "needs-cleanup" | "likely-misrecognized" | "router-error" | "no-local-transcript" | "needs-formatting";

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
export const CLEAN_QUESTION_INSTRUCTIONS =
  "This dictated transcript can be inserted exactly as-is: it has no filler words or " +
  "hesitations, no self-corrections or restarts, no spoken list that should be " +
  "formatted, correct punctuation, and no apparent speech-recognition errors (such as " +
  "garbled mixed Chinese/English words or misheard names/terms from the vocabulary).";

// Secondary question: only used (when the transcript isn't clean) to pick
// between the two failure reasons docs/API.md defines. Keeping this
// narrowly scoped to recognition errors specifically (rather than restating
// the whole primary question) is what makes it useful as a tie-breaker.
export const RECOGNITION_QUESTION_INSTRUCTIONS =
  "This transcript's words were all recognized correctly: no garbled or nonsensical " +
  "mixed Chinese/English word combinations, and no misheard names or terms that should " +
  "have matched the personal dictionary vocabulary provided in state.";

/**
 * Given a clean probability and (when not clean) a recognized probability,
 * applies docs/API.md's routing policy. Shared with
 * `lib/transcribe-routing.ts` so the "clean >= threshold" / reason
 * tie-break logic is defined in exactly one place.
 */
export function decideRoute(
  cleanProbability: number,
  recognizedProbability: number,
  threshold: number = CLEAN_THRESHOLD
): { needsCloud: boolean; reason: RouteReason } {
  const needsCloud = !(cleanProbability >= threshold);
  const reason: RouteReason = !needsCloud
    ? "clean"
    : recognizedProbability < threshold
      ? "likely-misrecognized"
      : "needs-cleanup";
  return { needsCloud, reason };
}

/**
 * Asks Jev whether `params.transcript` can be inserted as-is. Never throws:
 * any error, unexpected answer shape, breaker skip, or a call taking
 * longer than `timeoutMs` (default 1.5s, per docs/API.md) resolves to
 * `{ needsCloud: true, reason: "router-error" }` — routing failures must
 * never block dictation.
 */
export async function routeTranscript(params: RouteParams, timeoutMs = ROUTER_TIMEOUT_MS): Promise<RouteDecision> {
  const startedAt = performance.now();

  const parsed = await callJev({
    state: {
      transcript: params.transcript,
      languageHints: params.languageHints,
      vocabulary: params.vocabulary,
    },
    questions: {
      clean: { type: "boolean", instructions: CLEAN_QUESTION_INSTRUCTIONS },
      recognized: { type: "boolean", instructions: RECOGNITION_QUESTION_INSTRUCTIONS },
    },
    timeoutMs,
    parse: (result) => {
      const cleanAnswer = result.answers.clean;
      const recognizedAnswer = result.answers.recognized;
      if (!isBooleanAnswer(cleanAnswer) || !isBooleanAnswer(recognizedAnswer)) {
        throw new Error("Unexpected Jev answer shape (expected boolean answers)");
      }
      return { cleanProbability: cleanAnswer.probability, recognizedProbability: recognizedAnswer.probability };
    },
  });

  const latencyMs = Math.round(performance.now() - startedAt);
  if (parsed === null) {
    return { needsCloud: true, cleanProbability: null, reason: "router-error", latencyMs };
  }

  const { needsCloud, reason } = decideRoute(parsed.cleanProbability, parsed.recognizedProbability);
  return { needsCloud, cleanProbability: parsed.cleanProbability, reason, latencyMs };
}
