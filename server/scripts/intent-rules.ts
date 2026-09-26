/**
 * NON-AUTHORITATIVE eval-only port of the client-side bilingual (zh/en)
 * intent fallback rules described in docs/PROMPTS.md §5b.
 *
 * The real rules live in ProsioCore (Swift, `IntentRules`) and are owned by
 * core. This file exists ONLY so scripts/intent-eval.ts can estimate what
 * accuracy the client falls back to when Jev is unavailable — it is not
 * used by any server route and must never be imported from server code.
 *
 * Per docs/PROMPTS.md §5b, every rule is PREFIX-ONLY: the cue must sit at
 * the very start of the (trimmed) utterance, followed by a pause
 * (punctuation), "一下", or the content directly — a cue appearing
 * mid-sentence does not count, even though the word is present. (Fixed
 * 2026-09-26: the previous version of this file matched cues as
 * substrings anywhere in the text, which wrongly fired on text that only
 * *mentions* translation, e.g. "这段翻译得不太好" or "he works as a
 * translator" — see git history / the coordinator's follow-up for the
 * false-command cases this caused. It does not affect production: this
 * file is eval-only.)
 *
 *   - ask: 提问 / 问答 / 回答 / 请教 / 问一下 / 问问 / Prosio(,) / 普罗西奥 /
 *     "hey Prosio" / "question" / "quick question" — Chinese cues must be
 *     followed by punctuation, 一下, or a question body; never 请问 (too
 *     common in normal writing); never bare "Ask …".
 *   - translate: 翻译 / 翻成 / 译成 / 帮我翻译 / 用(英文|日语…)说 /
 *     "translate (this) (to|into) X" / "in English|Japanese…, " — target
 *     language from the cue, else the default.
 *   - otherwise: the default (dictate, or edit with a selection).
 */

export type RulesIntent = "dictate" | "edit" | "ask" | "translate";

export interface RulesParams {
  transcript: string;
  hasSelection: boolean;
}

export interface RulesDecision {
  intent: RulesIntent;
  matchedRule: "ask" | "translate" | "default";
}

function defaultIntent(hasSelection: boolean): RulesIntent {
  return hasSelection ? "edit" : "dictate";
}

// Chinese ask cues that must be followed by punctuation, "一下", or more text
// (a question body) — never bare, and never "请问" (too common in normal
// writing to be a reliable cue).
const ZH_ASK_CUES = ["提问", "问答", "回答", "请教", "问一下", "问问"];
const ZH_ASK_CUE_PATTERN = new RegExp(`^(?:${ZH_ASK_CUES.join("|")})(?:[，,。:：]|一下)?\\s*(.+)?$`);

// "Prosio" / "普罗西奥" as an ask cue, optionally followed by a comma.
const PROSIO_CUE_PATTERN = /^(?:prosio|普罗西奥)\s*[,，]?\s*(.+)$/i;

// English ask cues: "hey Prosio", "question", "quick question" — must be
// followed by content, never bare "ask ...".
const EN_ASK_CUE_PATTERN = /^(?:hey prosio|quick question|question)\s*[,:]?\s*(.+)$/i;

// Per docs/PROMPTS.md §5b: "a command cue at the start of the utterance,
// followed by a pause (punctuation) or directly by the content." All cues
// below are therefore anchored to the very start of the (trimmed)
// utterance (`^`) — a cue appearing mid-sentence (e.g. "把这句话翻译成英文",
// "can you help me translate the deck into French") does NOT count, even
// though the word is present. This is a deliberate, documented limitation
// of the rules relative to Jev's semantic understanding — see
// scripts/intent-eval.ts's --rules-only report for what it costs.
//
// Longer cues are listed before their prefixes ("帮我翻成"/"帮我翻译" before
// "翻成"/"翻译") so the regex alternation tries the more specific match first.
const ZH_TRANSLATE_CUES = ["帮我翻成", "帮我翻译", "翻成", "翻译", "译成"];
const ZH_TRANSLATE_CUE_PATTERN = new RegExp(`^(?:${ZH_TRANSLATE_CUES.join("|")})`);
const ZH_USE_LANGUAGE_PATTERN = /^用(?:[一-鿿]{1,4}|[a-zA-Z]+)(?:说|跟.*说)/;

const EN_TRANSLATE_PATTERN = /^translate\b.*\b(?:to|into)\b/i;
const EN_IN_LANGUAGE_PATTERN = /^in\s+[a-z]+\s*,/i;

/**
 * Non-authoritative TS port of the client's bilingual rules, for eval
 * comparison only. See file header.
 */
export function classifyIntentByRules(params: RulesParams): RulesDecision {
  const text = params.transcript.trim();

  if (ZH_ASK_CUE_PATTERN.test(text) && !text.startsWith("请问")) {
    const match = text.match(ZH_ASK_CUE_PATTERN);
    if (match && (match[1]?.trim() || text.includes("一下") || /[，,。:：]/.test(text))) {
      return { intent: "ask", matchedRule: "ask" };
    }
  }
  if (PROSIO_CUE_PATTERN.test(text)) {
    return { intent: "ask", matchedRule: "ask" };
  }
  if (EN_ASK_CUE_PATTERN.test(text)) {
    return { intent: "ask", matchedRule: "ask" };
  }

  if (ZH_TRANSLATE_CUE_PATTERN.test(text) || ZH_USE_LANGUAGE_PATTERN.test(text)) {
    return { intent: "translate", matchedRule: "translate" };
  }
  if (EN_TRANSLATE_PATTERN.test(text) || EN_IN_LANGUAGE_PATTERN.test(text)) {
    return { intent: "translate", matchedRule: "translate" };
  }

  return { intent: defaultIntent(params.hasSelection), matchedRule: "default" };
}
