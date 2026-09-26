// --- Cheap, deterministic "unformatted spoken list" guard (P1.2.1) --------
//
// docs/PROMPTS.md's auto-formatting update (2026-09-26): Gemini SMART
// reliably turns spoken lists into Markdown lists (live-verified,
// scripts/format-eval.ts), but the ON-DEVICE local transcript never is —
// it's raw ASR output. If the combined local-transcript check
// (lib/transcribe-routing.ts) ever decided a spoken-but-unformatted list
// was "clean" and skipped Gemini, the user would get a run-on
// comma-separated sentence inserted instead of the Markdown list SMART
// would have produced — a visible regression.
//
// Jev's `clean` question already covers this semantically ("no spoken list
// that should be formatted" is explicitly part of the router's
// instructions in lib/router.ts), so this SHOULD already be rare in
// practice. This guard exists as a cheap, independent backstop: a plain
// string check, evaluated BEFORE any Jev call, so it still forces the
// cloud path (and never blocks or adds Jev latency) even if Jev is wrong
// or unavailable.

// Enumeration cues: word-bounded for Latin words (avoids matching inside
// unrelated words like "firstname"), plain substring for CJK (word
// boundaries don't apply the same way, and these are short, spoken-list-
// specific phrases unlikely to appear incidentally).
const LATIN_ENUMERATION_CUES = ["first", "second", "third", "finally", "next"];
const CJK_ENUMERATION_CUES = ["第一", "第二", "第三", "首先", "其次", "最后", "一是", "二是"];

const LATIN_ENUMERATION_PATTERN = new RegExp(`\\b(?:${LATIN_ENUMERATION_CUES.join("|")})\\b`, "gi");

// List-intro cues: signal the transcript is introducing a set of points,
// even without explicit ordinals ("以下几点是...", "a few things:", ...).
const LIST_INTRO_CUES = ["以下", "几点", "几件事", "几个", "points", "things"];

function countEnumerationCues(text: string): number {
  const latinMatches = text.match(LATIN_ENUMERATION_PATTERN)?.length ?? 0;
  let cjkMatches = 0;
  for (const cue of CJK_ENUMERATION_CUES) {
    if (text.includes(cue)) cjkMatches++;
  }
  return latinMatches + cjkMatches;
}

/**
 * Counts 、/，/,-separated clauses following a colon, or following a
 * list-intro cue when there's no colon. A plain narrative sentence with a
 * couple of commas won't reach 3 non-trivial clauses; a dictated list
 * ("以下几点：新版本上线，客服培训，加监控") will.
 */
function countListLikeClauses(text: string): number {
  const hasColon = /[:：]/.test(text);
  const hasIntroCue = LIST_INTRO_CUES.some((cue) => text.toLowerCase().includes(cue.toLowerCase()));
  if (!hasColon && !hasIntroCue) return 0;

  const afterColon = hasColon ? text.split(/[:：]/).slice(1).join("：") : text;
  return afterColon
    .split(/[、，,]/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0).length;
}

export interface ListGuardResult {
  triggered: boolean;
  enumerationCueCount: number;
  listLikeClauseCount: number;
}

/**
 * Returns `triggered: true` when `transcript` looks like an unformatted
 * spoken list that Gemini SMART would reformat: ≥2 enumeration cues
 * (第一/第二/第三/首先/其次/最后/一是/二是/first/second/third/finally/next), OR
 * ≥3 、/，/,-separated clauses following a colon or a list-intro cue
 * (以下/几点/几件事/几个/points/things).
 */
export function needsFormattingGuard(transcript: string): ListGuardResult {
  const enumerationCueCount = countEnumerationCues(transcript);
  const listLikeClauseCount = countListLikeClauses(transcript);
  return {
    triggered: enumerationCueCount >= 2 || listLikeClauseCount >= 3,
    enumerationCueCount,
    listLikeClauseCount,
  };
}
