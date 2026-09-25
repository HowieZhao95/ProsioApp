// Text normalisation shared by CER computation and heuristics: lowercase,
// strip punctuation (ASCII + common CJK), collapse whitespace. Keeps letters
// (incl. CJK ideographs) and digits only, separated by single spaces.

// ASCII + full-width/CJK punctuation and symbols we treat as noise for CER.
const PUNCTUATION_RE =
  /[.,/#!$%^&*;:{}=\-_`~()[\]<>"'?，。、；：“”‘’（）《》【】！？—…·]/g;

export function normalizeText(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(PUNCTUATION_RE, " ")
    .replace(/\s+/g, " ")
    .trim();
}
