// --- Markdown bullet-marker normalization (auto-formatting follow-up) -----
//
// docs/PROMPTS.md's formatting conventions describe Markdown lists as
// "- " bullets / "1. " numbered — but model output (Gemini SMART on
// POST /api/transcribe's cloud path, and occasionally a compose model on
// non-ask POST /api/compose output) sometimes uses other equivalent bullet
// glyphs ("* ", "• ", "· ", "– "). This normalizes all of those to "- " so
// the client always sees one consistent bullet marker, regardless of which
// one the model happened to emit.
//
// Rules:
//  - Only a bullet marker at the very start of a line (after optional
//    leading whitespace/indentation), followed by whitespace, is
//    normalized — never a marker character appearing mid-line.
//  - Numbered markers ("1. ", "2. ", …) are left untouched entirely.
//  - Mid-line emphasis ("*bold*", "**bold**") is never touched: the
//    line-start pattern requires the marker character to be immediately
//    followed by whitespace, which "**bold**" (asterisk immediately
//    followed by another asterisk) and "*Note...*" (asterisk immediately
//    followed by a non-space character) never satisfy.
//  - Lines inside a fenced code block (``` ... ```) are left completely
//    untouched, including the fence delimiter lines themselves — a line's
//    own leading "```" toggles fence state but is never itself rewritten.

const FENCE_LINE_RE = /^\s*```/;
const BULLET_MARKER_RE = /^(\s*)[*•·–]\s+/;

export function normalizeListMarkers(text: string): string {
  const lines = text.split("\n");
  let inFence = false;

  const normalized = lines.map((line) => {
    if (FENCE_LINE_RE.test(line)) {
      inFence = !inFence;
      return line;
    }
    if (inFence) return line;
    return line.replace(BULLET_MARKER_RE, "$1- ");
  });

  return normalized.join("\n");
}
