import type { EvalCase } from "./types";

export interface HeuristicResult {
  name: string;
  passed: boolean;
  detail?: string;
}

// True disfluency interjections — never legitimate content in a SMART-mode
// transcript. Deliberately narrower than words like "那个"/"就是"/"like",
// which can be meaningful connectives ("that is", "just", "similar to").
const ZH_FILLER_TOKENS = ["嗯", "呃", "唔"];
const EN_FILLER_TOKENS = ["um", "uh", "umm", "uhh", "erm"];

const CORRECTION_MARKERS = [
  "不对",
  "不是",
  "啊不是",
  "啊不对",
  "actually no",
  "actually, no",
  "i mean,",
  "sorry, i mean",
  "wait no",
  "wait, no",
];

function containsWholeWord(haystack: string, needle: string): boolean {
  if (/[a-z]/i.test(needle)) {
    const re = new RegExp(`(^|[^a-z0-9])${needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}([^a-z0-9]|$)`, "i");
    return re.test(haystack);
  }
  return haystack.includes(needle);
}

function fillersAbsent(hypothesis: string): HeuristicResult {
  const lower = hypothesis.toLowerCase();
  const leaked = [...ZH_FILLER_TOKENS, ...EN_FILLER_TOKENS].filter((tok) => containsWholeWord(lower, tok));
  return {
    name: "fillers-absent",
    passed: leaked.length === 0,
    detail: leaked.length ? `Leaked filler token(s): ${leaked.join(", ")}` : undefined,
  };
}

function correctionMarkersAbsent(hypothesis: string): HeuristicResult {
  const lower = hypothesis.toLowerCase();
  const leaked = CORRECTION_MARKERS.filter((m) => lower.includes(m.toLowerCase()));
  return {
    name: "correction-resolved",
    passed: leaked.length === 0,
    detail: leaked.length ? `Correction discourse marker(s) leaked into final text: ${leaked.join(", ")}` : undefined,
  };
}

function listFormatted(hypothesis: string, expected: string): HeuristicResult {
  const marker = /(^|\n)\s*\d+[.、)]/gm;
  const gotCount = (hypothesis.match(marker) ?? []).length;
  const wantCount = (expected.match(marker) ?? []).length;
  const passed = gotCount >= Math.max(1, wantCount - 1); // allow off-by-one formatting drift
  return {
    name: "list-formatted",
    passed,
    detail: `Found ${gotCount} numbered line(s), expected ~${wantCount}`,
  };
}

function scriptPreserved(hypothesis: string): HeuristicResult {
  const hasLatin = /[a-z]/i.test(hypothesis);
  const hasCJK = /[一-鿿]/.test(hypothesis);
  return {
    name: "mixed-script-preserved",
    passed: hasLatin && hasCJK,
    detail: !hasLatin ? "No Latin-script text found" : !hasCJK ? "No CJK text found" : undefined,
  };
}

function vocabularyHonored(hypothesis: string, vocabulary: string[]): HeuristicResult {
  const lower = hypothesis.toLowerCase();
  const missing = vocabulary.filter((term) => !containsWholeWord(lower, term));
  return {
    name: "vocabulary-honored",
    passed: missing.length === 0,
    detail: missing.length ? `Missing vocabulary term(s): ${missing.join(", ")}` : undefined,
  };
}

function punctuated(hypothesis: string, expected: string): HeuristicResult {
  const marker = /[.?!。？！]/g;
  const got = (hypothesis.match(marker) ?? []).length;
  const want = (expected.match(marker) ?? []).length;
  const passed = want === 0 || got >= Math.ceil(want * 0.6);
  return {
    name: "punctuated",
    passed,
    detail: `Found ${got} terminal punctuation mark(s), expected ~${want}`,
  };
}

function lengthInRange(hypothesis: string, expected: string): HeuristicResult {
  const gotLen = Array.from(hypothesis).length;
  const wantLen = Array.from(expected).length;
  const ratio = wantLen === 0 ? 1 : gotLen / wantLen;
  const passed = ratio >= 0.5 && ratio <= 1.6;
  return {
    name: "length-in-range",
    passed,
    detail: `Output is ${Math.round(ratio * 100)}% of expected length`,
  };
}

/** Runs the pass/fail heuristics applicable to a case's category, plus a baseline filler check for every case. */
export function runHeuristics(kase: EvalCase, hypothesis: string): HeuristicResult[] {
  const results: HeuristicResult[] = [fillersAbsent(hypothesis)];

  switch (kase.category) {
    case "self-correction":
      results.push(correctionMarkersAbsent(hypothesis));
      break;
    case "list":
      results.push(listFormatted(hypothesis, kase.expected));
      break;
    case "code-switch":
      if (kase.language === "mixed") results.push(scriptPreserved(hypothesis));
      break;
    case "names-jargon":
      results.push(vocabularyHonored(hypothesis, kase.vocabulary));
      break;
    case "punctuation":
      results.push(punctuated(hypothesis, kase.expected));
      break;
    case "long-form":
      results.push(lengthInRange(hypothesis, kase.expected));
      break;
    case "filler":
      // Covered by the baseline fillers-absent check above.
      break;
  }

  return results;
}
