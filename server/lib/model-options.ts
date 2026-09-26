// Shared compose-model default + per-model call-option capabilities, used
// by both POST /api/compose (app/api/compose/route.ts) and the P1.2.1
// list-repair step in POST /api/transcribe (lib/list-repair.ts) — kept in
// one place so the two call sites can't drift when the default model or
// its capabilities change.

// Chosen by the user, 2026-09-26, after the live model bake-off
// (scripts/compose-bakeoff.ts) found openai/gpt-6-luna the cheapest
// candidate tested ($0.052/1k req), 100% robustness, and clean on the
// Edit no-additions threat case 3/3 — see server/README.md's Compose
// section for the full results table.
export const DEFAULT_COMPOSE_MODEL = "openai/gpt-6-luna";

/** `PROSIO_COMPOSE_MODEL` env override, else the default. */
export function composeModelId(): string {
  return process.env.PROSIO_COMPOSE_MODEL || DEFAULT_COMPOSE_MODEL;
}

// Both openai/gpt-6-luna and openai/gpt-5.4-mini are OpenAI reasoning
// models: they reject `temperature` outright (the Gateway logs "temperature
// is not supported for reasoning models" on every call if you send it) and
// don't need it — it's omitted entirely for these rather than sent as a
// value the model ignores anyway, so logs stay clean. Every other model
// tested so far (anthropic/claude-haiku-4.5, google/gemini-3.x, minimax/*)
// accepts temperature normally.
export const MODELS_WITHOUT_TEMPERATURE = new Set(["openai/gpt-6-luna", "openai/gpt-5.4-mini"]);

// gpt-6-luna accepts reasoningEffort "none"/"low"/"medium"/"high"/"xhigh"/"max"
// — NOT "minimal" (confirmed live: Gateway rejects it with a warning naming
// the valid set). "none" is the lowest-latency option, which is what both
// compose and the (latency-sensitive, 2s-timeout) list-repair step want.
export const REASONING_EFFORT_BY_MODEL: Record<string, string> = {
  "openai/gpt-6-luna": "none",
};

export function callOptionsFor(
  modelId: string,
  temperature: number
): { temperature?: number; providerOptions?: { openai: { reasoningEffort: string } } } {
  const opts: { temperature?: number; providerOptions?: { openai: { reasoningEffort: string } } } = {};
  if (!MODELS_WITHOUT_TEMPERATURE.has(modelId)) {
    opts.temperature = temperature;
  }
  const reasoningEffort = REASONING_EFFORT_BY_MODEL[modelId];
  if (reasoningEffort) {
    opts.providerOptions = { openai: { reasoningEffort } };
  }
  return opts;
}
