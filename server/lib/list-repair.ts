import { generateText } from "ai";
import { gateway } from "./gateway";
import { needsListRepair } from "./list-guard";
import { callOptionsFor, composeModelId } from "./model-options";
import { buildListRepairPrompt, sanitizeComposeOutput } from "./prompts";
import { normalizeListMarkers } from "./text-format";

// --- List repair after transcription (P1.2.1 follow-up, docs/PROMPTS.md §1b) ---
//
// Server-only, inside POST /api/transcribe, after Gemini + bullet-marker
// normalization and before intent reclassification. Repairs the observed
// gap from scripts/format-eval.ts: SMART sometimes leaves a mixed zh/en
// implicit (no-ordinal) spoken list as one run-on sentence instead of
// formatting it as a Markdown list. Runs the compose model (gpt-6-luna,
// reasoning none — lib/model-options.ts) ONLY when
// `needsListRepair()` (lib/list-guard.ts) fires, with a tight 2s timeout
// and a strict content-preserving safety check before accepting the result.

export const LIST_REPAIR_TIMEOUT_MS = 2000;

export type FormatRepairOutcome = "applied" | "rejected" | "timeout" | null;

export interface ListRepairResult {
  text: string;
  formatRepair: FormatRepairOutcome;
  latencyMs: number;
}

// Joining connectors the repair prompt is explicitly allowed to add/move as
// part of reformatting (docs/PROMPTS.md §1b's rule: "the commas or
// conjunctions that join the items"). Stripped from both sides before the
// safety comparison so legitimately relocating/dropping them (e.g. turning
// "A，然后B，还有C" into a 3-item list) doesn't fail the check.
const CONNECTORS = ["然后", "还有", "以及", "和", "跟", "and", "then", "also", "plus"];
const LATIN_CONNECTOR_RE = new RegExp(`\\b(?:${CONNECTORS.filter((c) => /^[a-z]+$/i.test(c)).join("|")})\\b`, "gi");
const CJK_CONNECTORS = CONNECTORS.filter((c) => !/^[a-z]+$/i.test(c));

// Broad punctuation set (Latin + CJK) stripped for the safety comparison —
// deliberately generous since the repair prompt is allowed to change
// exactly this class of character (line breaks, list markers, joining
// punctuation).
const PUNCTUATION_RE = /[\s.,!?;:，。！？；：、"'"'()（）\[\]【】\-—–*•·]/g;
const LIST_MARKER_RE = /^\s*(?:[-*•·–]\s+|\d+[.、]\s*)/gm;

/**
 * Normalizes text for the safety comparison: removes list markers first
 * (they're line-anchored), then connectors, then all remaining whitespace
 * and punctuation, then lowercases (case-insensitive for Latin — CJK has no
 * case). What's left is the "content-only" character sequence.
 */
function stripForComparison(text: string): string {
  let s = text.replace(LIST_MARKER_RE, "");
  s = s.replace(LATIN_CONNECTOR_RE, "");
  for (const connector of CJK_CONNECTORS) {
    s = s.split(connector).join("");
  }
  s = s.replace(PUNCTUATION_RE, "");
  return s.toLowerCase();
}

/**
 * The result is accepted only if, after removing whitespace, list markers,
 * punctuation and the joining connectors, it contains exactly the same
 * characters in the same order as the input with the same removals
 * (docs/PROMPTS.md §1b) — i.e. the model only relaid out the text, never
 * changed, added, dropped, reordered or translated a word.
 */
export function passesListRepairSafetyCheck(original: string, repaired: string): boolean {
  return stripForComparison(original) === stripForComparison(repaired);
}

/**
 * Runs the list-repair step on `text` (the final, post-Gemini,
 * post-marker-normalization transcript). Returns the original text
 * unchanged (with `formatRepair: null`) when the detector doesn't fire.
 * Never throws: a timeout, model error, or failed safety check all fall
 * back to the original text with the matching `formatRepair` outcome.
 */
export async function repairListFormatting(text: string): Promise<ListRepairResult> {
  const startedAt = performance.now();

  if (!needsListRepair(text)) {
    return { text, formatRepair: null, latencyMs: Math.round(performance.now() - startedAt) };
  }

  const modelId = composeModelId();
  const prompt = buildListRepairPrompt({ transcript: text });
  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), LIST_REPAIR_TIMEOUT_MS);

  try {
    const result = await generateText({
      model: gateway(modelId),
      system: prompt.system,
      messages: prompt.messages,
      abortSignal: abortController.signal,
      ...callOptionsFor(modelId, 0.2),
    });

    const repaired = normalizeListMarkers(sanitizeComposeOutput(result.text));
    const latencyMs = Math.round(performance.now() - startedAt);

    if (passesListRepairSafetyCheck(text, repaired)) {
      return { text: repaired, formatRepair: "applied", latencyMs };
    }
    return { text, formatRepair: "rejected", latencyMs };
  } catch {
    const latencyMs = Math.round(performance.now() - startedAt);
    // AbortController.abort() (our own 2s timeout) and any other model/
    // network failure both land here; distinguish by whether OUR signal is
    // the one that fired, so an unrelated failure isn't mislabeled "timeout".
    const outcome: FormatRepairOutcome = abortController.signal.aborted ? "timeout" : "rejected";
    return { text, formatRepair: outcome, latencyMs };
  } finally {
    clearTimeout(timeout);
  }
}
