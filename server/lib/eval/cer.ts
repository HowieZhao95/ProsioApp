import { normalizeText } from "./normalize";

/** Character-level Levenshtein distance, Unicode-code-point aware. */
export function levenshtein(a: string, b: string): number {
  const s = Array.from(a);
  const t = Array.from(b);
  const n = s.length;
  const m = t.length;
  if (n === 0) return m;
  if (m === 0) return n;

  let prev = new Array<number>(m + 1);
  let curr = new Array<number>(m + 1);
  for (let j = 0; j <= m; j++) prev[j] = j;

  for (let i = 1; i <= n; i++) {
    curr[0] = i;
    for (let j = 1; j <= m; j++) {
      const cost = s[i - 1] === t[j - 1] ? 0 : 1;
      const deletion = prev[j]! + 1;
      const insertion = curr[j - 1]! + 1;
      const substitution = prev[j - 1]! + cost;
      curr[j] = Math.min(deletion, insertion, substitution);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[m]!;
}

export interface CerResult {
  /** Edit distance / reference length, after normalisation. 0 = perfect, can exceed 1. */
  cer: number;
  editDistance: number;
  referenceLength: number;
  normalizedHypothesis: string;
  normalizedReference: string;
}

/** Character Error Rate of `hypothesis` against `reference`, after normalising punctuation/whitespace/case. */
export function characterErrorRate(hypothesis: string, reference: string): CerResult {
  const normalizedHypothesis = normalizeText(hypothesis);
  const normalizedReference = normalizeText(reference);
  const editDistance = levenshtein(normalizedHypothesis, normalizedReference);
  const referenceLength = Array.from(normalizedReference).length;
  const cer = referenceLength === 0 ? (editDistance === 0 ? 0 : 1) : editDistance / referenceLength;
  return { cer, editDistance, referenceLength, normalizedHypothesis, normalizedReference };
}
