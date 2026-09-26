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

// --- Invented-signature guard for "write" output (2026-09-26 follow-up) ---
//
// Live test found `openai/gpt-6-luna` signing a drafted email with a made-up
// name ("班尼") the user never gave it — docs/PROMPTS.md §4b's email rule
// now explicitly forbids a name/initials/signature in the closing (only a
// plain "谢谢！"/"Thanks," line), but a prompt rule alone doesn't guarantee
// compliance. This is a deterministic backstop, independent of the prompt:
// if the output's last non-empty line looks like an invented name/signature
// sitting right after a closing line, and that line doesn't genuinely
// appear anywhere in the instruction or context, it's dropped.
//
// Deliberately narrow (false negatives are fine — this only needs to catch
// the observed failure mode, not every conceivable one):
//  - Only applies to the very LAST non-empty line, only when the line right
//    before it looks like a closing (ends with "!"/"！"/","/"，", or starts
//    with a closing word like "谢谢"/"thanks"/"regards").
//  - "Looks like a name/signature": ≤12 chars, and either 2-4 bare CJK
//    characters with no punctuation, or 1-3 Latin words each starting with
//    a capital letter, with no punctuation.
//  - Never drops a line that genuinely appears (case-insensitively for
//    Latin) in the instruction or the selected context — the user may have
//    legitimately dictated that exact short line.

const CJK_NAME_RE = /^[一-鿿]{2,4}$/;
const LATIN_NAME_RE = /^[A-Z][A-Za-z'-]*(?:\s+[A-Z][A-Za-z'-]*){0,2}$/;
const CLOSING_PUNCTUATION_RE = /[!！,，]\s*$/;
// CJK closing words are matched by plain prefix (not `\b`): `\b` is defined
// in terms of ASCII `\w`, so it never finds a boundary next to a CJK
// character (neither side counts as a "word" character) and silently fails
// to match a bare closing word like "谢谢" with no trailing punctuation.
const CJK_CLOSING_WORDS = ["谢谢", "多谢", "敬上", "此致", "敬礼"];
const LATIN_CLOSING_WORDS_RE = /^(?:thanks|thank you|regards|best regards|best|sincerely|cheers)\b/i;

function looksLikeClosingLine(line: string): boolean {
  const trimmed = line.trim();
  if (trimmed.length === 0) return false;
  if (CLOSING_PUNCTUATION_RE.test(trimmed)) return true;
  if (CJK_CLOSING_WORDS.some((word) => trimmed.startsWith(word))) return true;
  return LATIN_CLOSING_WORDS_RE.test(trimmed);
}

function looksLikeNameOrSignature(line: string): boolean {
  const trimmed = line.trim();
  return trimmed.length > 0 && trimmed.length <= 12 && (CJK_NAME_RE.test(trimmed) || LATIN_NAME_RE.test(trimmed));
}

function lastNonEmptyLineIndex(lines: string[], before = lines.length): number {
  for (let i = before - 1; i >= 0; i--) {
    if (lines[i]!.trim().length > 0) return i;
  }
  return -1;
}

export function stripInventedWriteSignature(output: string, instruction: string, context?: string | null): string {
  const lines = output.split("\n");
  const lastIdx = lastNonEmptyLineIndex(lines);
  if (lastIdx <= 0) return output; // no content, or only one line — no "line before it" to be a closing

  const lastLine = lines[lastIdx]!.trim();
  if (!looksLikeNameOrSignature(lastLine)) return output;

  const prevIdx = lastNonEmptyLineIndex(lines, lastIdx);
  if (prevIdx === -1 || !looksLikeClosingLine(lines[prevIdx]!)) return output;

  const haystack = `${instruction}\n${context ?? ""}`.toLowerCase();
  if (haystack.includes(lastLine.toLowerCase())) return output; // genuinely dictated — keep it

  return lines.slice(0, lastIdx).join("\n").replace(/[ \t]+$/, "");
}
