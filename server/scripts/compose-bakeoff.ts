#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * One-off model bake-off for POST /api/compose, requested after the Edit
 * no-additions fix, on the FULL eval/compose-cases.json set (all modes,
 * incl. the no-additions/additions-expected/robustness categories), each
 * case run twice per candidate to reduce noise. Reports per-mode quality,
 * faithfulness, no-additions pass rate, robustness pass rate, format
 * failures (incl. <think> leakage), TTFT/total latency percentiles, and a
 * $/1k-requests cost estimate from Gateway's own per-token pricing
 * (`gateway.getAvailableModels()`).
 *
 * This does NOT change any default — report only (see server/README.md /
 * the agent's report for the recommendation).
 *
 * Usage (from server/):
 *   npx tsx --env-file=../.env.local scripts/compose-bakeoff.ts
 *   npx tsx --env-file=../.env.local scripts/compose-bakeoff.ts --candidates google/gemini-3.8-flash --runs 1
 *
 * Requires AI_GATEWAY_API_KEY.
 */

import { readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { generateObject, streamText } from "ai";
import { z } from "zod";

import { gateway } from "../lib/gateway";
import {
  buildAskPrompt,
  buildEditPrompt,
  buildRewritePrompt,
  buildTranslatePrompt,
  sanitizeComposeOutput,
  type ComposeApp,
  type ComposeHistoryTurn,
  type ComposeMode,
  type ComposePrompt,
  type ComposeScene,
} from "../lib/prompts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EVAL_DIR = resolve(__dirname, "../../eval");
const CASES_PATH = join(EVAL_DIR, "compose-cases.json");
const RESULTS_DIR = join(EVAL_DIR, "results");

// Requested candidates. deepseek/deepseek-v4.1-flash is BLOCKED in this
// environment's Gateway project (403 "Your team has restricted access to
// this model... Model Allowlist") — same class of issue as typesafe-ai/jev
// in the routing task. Confirmed via a live probe (2026-09-26), not a
// code/request-shape problem. (openai/gpt-6-luna had the same restriction
// but was allowlisted the same day — see BLOCKED_CANDIDATES below.) Skipped
// with a note in the report; re-run once allowlisted.
const REQUESTED_CANDIDATES = [
  "openai/gpt-6-luna",
  "deepseek/deepseek-v4.1-flash",
  "google/gemini-3.8-flash",
  "minimax/minimax-m2.7",
  "minimax/minimax-m2.7-highspeed",
  "anthropic/claude-haiku-4.5",
];
// openai/gpt-6-luna was allowlisted 2026-09-26 (confirmed live) and removed
// from this set. deepseek/deepseek-v4.1-flash remains restricted (403,
// re-confirmed the same day) — update this set if/when that changes too.
const BLOCKED_CANDIDATES = new Set(["deepseek/deepseek-v4.1-flash"]);

const JUDGE_MODEL = "anthropic/claude-opus-4.5";
const DEFAULT_RUNS_PER_CASE = 2;

// --- case schema (same shape as compose-eval.ts) ---------------------------

const caseSchema = z.object({
  id: z.string(),
  mode: z.enum(["rewrite", "translate", "edit", "ask"]),
  category: z.enum(["normal", "robustness", "no-additions", "additions-expected"]),
  text: z.string(),
  selection: z.string().nullable().optional(),
  scene: z.enum(["general", "email", "chat", "code", "document"]).optional(),
  targetLanguage: z.string().nullable().optional(),
  app: z
    .object({
      bundleID: z.string().nullable().optional(),
      appName: z.string().nullable().optional(),
      windowTitle: z.string().nullable().optional(),
      url: z.string().nullable().optional(),
    })
    .nullable()
    .optional(),
  vocabulary: z.array(z.string()).default([]),
  history: z.array(z.object({ role: z.enum(["user", "assistant"]), text: z.string() })).default([]),
  robustnessCheck: z.string().optional(),
  additionsExpected: z.boolean().optional(),
  note: z.string().optional(),
});
type ComposeCase = z.infer<typeof caseSchema>;

function loadCases(): ComposeCase[] {
  const raw = JSON.parse(readFileSync(CASES_PATH, "utf8"));
  const parsed = z.array(caseSchema).safeParse(raw);
  if (!parsed.success) {
    console.error(`eval/compose-cases.json failed validation:\n${parsed.error.message}`);
    process.exit(1);
  }
  return parsed.data;
}

function promptFor(kase: ComposeCase): ComposePrompt {
  const scene: ComposeScene = kase.scene ?? "general";
  const app: ComposeApp | null | undefined = kase.app;
  switch (kase.mode) {
    case "rewrite":
      return buildRewritePrompt({ transcript: kase.text, scene, app, vocabulary: kase.vocabulary });
    case "translate":
      return buildTranslatePrompt({ transcript: kase.text, targetLanguage: kase.targetLanguage ?? "en-US", scene, app, vocabulary: kase.vocabulary });
    case "edit":
      return buildEditPrompt({ selection: kase.selection ?? "", instruction: kase.text, vocabulary: kase.vocabulary });
    case "ask":
      return buildAskPrompt({ question: kase.text, app, selection: kase.selection, history: kase.history as ComposeHistoryTurn[] });
  }
}

// --- pricing -----------------------------------------------------------

interface Pricing {
  inputPerToken: number;
  outputPerToken: number;
}

async function loadPricing(modelIds: string[]): Promise<Map<string, Pricing>> {
  const res = await gateway.getAvailableModels();
  const map = new Map<string, Pricing>();
  for (const id of modelIds) {
    const m = res.models.find((x) => x.id === id);
    if (m?.pricing?.input && m.pricing.output) {
      map.set(id, { inputPerToken: Number(m.pricing.input), outputPerToken: Number(m.pricing.output) });
    }
  }
  return map;
}

// --- think-tag stripping ------------------------------------------------

const THINK_TAG_RE = /<think(?:ing)?>[\s\S]*?<\/think(?:ing)?>/gi;

function stripThink(text: string): { stripped: string; hadThink: boolean } {
  const hadThink = new RegExp(THINK_TAG_RE.source, "i").test(text);
  const stripped = text.replace(THINK_TAG_RE, "").trim();
  return { stripped, hadThink };
}

// --- reasoning-effort handling -------------------------------------------

/**
 * Minimal-reasoning-effort provider option, applied only where we have a
 * confirmed AI SDK convention for it. Currently: OpenAI reasoning models
 * (`providerOptions.openai.reasoningEffort`). Not independently
 * re-verified against @ai-sdk/openai's installed types in this
 * environment (that package isn't a direct dependency here — Gateway
 * proxies generically) — this is the documented AI SDK convention. Other
 * providers (deepseek/minimax/google) don't have a confirmed equivalent
 * available here, so none is set for them; if they turn out to be
 * reasoning models, that's reported as-is rather than guessed at.
 */
function reasoningProviderOptions(modelId: string, effort: string | null): { openai: { reasoningEffort: string } } | undefined {
  if (modelId.startsWith("openai/") && effort) {
    return { openai: { reasoningEffort: effort } };
  }
  return undefined;
}

// --- generation ----------------------------------------------------------

interface GenerationResult {
  rawText: string;
  text: string; // after think-strip + (non-ask) sanitize
  hadThink: boolean;
  ttftMs: number;
  totalMs: number;
  inputTokens?: number;
  outputTokens?: number;
  isReasoningModel: boolean;
  /** null = no temperature-related warning seen; true/false once we know. Only meaningful when the call didn't error. */
  temperatureHonored: boolean | null;
  reasoningEffortSet: string | null;
  error?: string;
}

async function generate(modelId: string, mode: ComposeMode, prompt: ComposePrompt, effort: string | null): Promise<GenerationResult> {
  const startedAt = performance.now();
  const providerOptions = reasoningProviderOptions(modelId, effort);
  const requestedTemperature = mode === "ask" ? 0.4 : 0.2;
  try {
    const result = streamText({
      model: gateway(modelId),
      system: prompt.system,
      messages: prompt.messages,
      temperature: requestedTemperature,
      providerOptions,
    });

    let ttftMs = -1;
    let raw = "";
    for await (const chunk of result.textStream) {
      if (ttftMs === -1) ttftMs = performance.now() - startedAt;
      raw += chunk;
    }
    const totalMs = performance.now() - startedAt;
    const warnings = await Promise.resolve(result.warnings).catch(() => []);
    const usage = await Promise.resolve(result.usage).catch(() => undefined);
    const warningsText = JSON.stringify(warnings).toLowerCase();
    const isReasoningModel = warningsText.includes("reasoning");
    const temperatureHonored = !warningsText.includes("temperature");

    const { stripped, hadThink } = stripThink(raw);
    const text = mode === "ask" ? stripped : sanitizeComposeOutput(stripped);

    return {
      rawText: raw,
      text,
      hadThink,
      ttftMs: ttftMs === -1 ? totalMs : ttftMs,
      totalMs,
      inputTokens: usage?.inputTokens,
      outputTokens: usage?.outputTokens,
      isReasoningModel,
      temperatureHonored,
      reasoningEffortSet: providerOptions ? effort : null,
    };
  } catch (err) {
    const totalMs = performance.now() - startedAt;
    return {
      rawText: "",
      text: "",
      hadThink: false,
      ttftMs: totalMs,
      totalMs,
      isReasoningModel: false,
      temperatureHonored: null,
      reasoningEffortSet: providerOptions ? effort : null,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

// --- judging (same approach as compose-eval.ts: exact system prompt as context) ---

const judgeScoreSchema = z.object({
  faithfulness: z.number().min(0).max(1),
  formatCompliance: z.number().min(0).max(1),
  injectionResistance: z.number().min(0).max(1),
  quality: z.number().min(0).max(1),
  hasInventedContent: z.boolean(),
  passed: z.boolean(),
  rationale: z.string(),
});
type JudgeScore = z.infer<typeof judgeScoreSchema>;

function judgePrompt(kase: ComposeCase, prompt: ComposePrompt, output: string): string {
  const lines: string[] = [
    `Mode: ${kase.mode}`,
    kase.scene ? `Scene: ${kase.scene}` : "",
    kase.targetLanguage ? `Target language: ${kase.targetLanguage}` : "",
    "",
    "--- The EXACT system prompt (rules) the candidate model was given for this call — use these rules, not a generic rubric ---",
    prompt.system,
    "",
    kase.mode === "edit" ? `<selected_text>\n${kase.selection}\n</selected_text>` : `<dictated_or_asked_text>\n${kase.text}\n</dictated_or_asked_text>`,
    kase.mode === "edit" ? `<instruction>\n${kase.text}\n</instruction>` : "",
    kase.mode === "ask" && kase.selection ? `<context_selection>\n${kase.selection}\n</context_selection>` : "",
    "",
    "--- Candidate model's output ---",
    output || "(empty output)",
    "",
  ];
  if (kase.robustnessCheck) {
    lines.push("--- Specific check for this case ---", kase.robustnessCheck, "");
  }
  lines.push(
    "Score against the EXACT system prompt above, not a generic notion of a good rewrite/translation/edit/answer. " +
      "faithfulness, formatCompliance, injectionResistance, quality: 0-1 each. hasInventedContent: literal yes/no — " +
      "does the output contain any claim/reason/detail/example/promise/sentence not derivable from the source? " +
      "passed: would you actually let this be inserted for the user, given the exact rules above?"
  );
  return lines.filter(Boolean).join("\n");
}

async function judge(kase: ComposeCase, prompt: ComposePrompt, output: string): Promise<JudgeScore> {
  const { object } = await generateObject({ model: gateway(JUDGE_MODEL), schema: judgeScoreSchema, prompt: judgePrompt(kase, prompt, output), temperature: 0 });
  return object;
}

// --- concurrency ---------------------------------------------------------

async function mapWithConcurrency<T, R>(items: T[], concurrency: number, fn: (item: T, index: number) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]!, i);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  return results;
}

// --- stats -----------------------------------------------------------------

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx]!;
}
function mean(values: number[]): number {
  return values.length ? values.reduce((a, b) => a + b, 0) / values.length : NaN;
}

// --- main --------------------------------------------------------------

interface RunResult {
  caseId: string;
  mode: ComposeMode;
  category: ComposeCase["category"];
  runIndex: number;
  effort: string | null;
  gen: GenerationResult;
  score?: JudgeScore;
}

/** Parses `--extra-runs modelId=n` (repeatable via comma: `modelA=3,modelB=5`). */
function parseRunOverrides(argv: string[]): Map<string, number> {
  const map = new Map<string, number>();
  const idx = argv.indexOf("--extra-runs");
  if (idx === -1) return map;
  for (const pair of (argv[idx + 1] ?? "").split(",")) {
    const [id, n] = pair.split("=");
    if (id && n) map.set(id, Number(n));
  }
  return map;
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const candidatesArg = argv.includes("--candidates") ? argv[argv.indexOf("--candidates") + 1] : undefined;
  const concurrency = argv.includes("--concurrency") ? Number(argv[argv.indexOf("--concurrency") + 1]) : 10;
  const runsPerCase = argv.includes("--runs") ? Number(argv[argv.indexOf("--runs") + 1]) : DEFAULT_RUNS_PER_CASE;
  const runOverrides = parseRunOverrides(argv); // e.g. --extra-runs openai/gpt-6-luna=3
  const reasoningEffortsArg = argv.includes("--reasoning-efforts") ? argv[argv.indexOf("--reasoning-efforts") + 1] : undefined;
  const reasoningEfforts = reasoningEffortsArg ? reasoningEffortsArg.split(",") : null; // e.g. --reasoning-efforts none,minimal,low ; applied only to openai/* candidates
  const headToHeadArg = (argv.includes("--head-to-head") ? argv[argv.indexOf("--head-to-head") + 1] : undefined) ?? "openai/gpt-6-luna,anthropic/claude-haiku-4.5";
  const [headToHeadA, headToHeadB] = headToHeadArg.split(",");

  if (!process.env.AI_GATEWAY_API_KEY) {
    console.error("AI_GATEWAY_API_KEY is not set. Run with --env-file=../.env.local or export it.");
    process.exit(1);
  }

  const requested = candidatesArg ? candidatesArg.split(",") : REQUESTED_CANDIDATES;
  const skipped = requested.filter((c) => BLOCKED_CANDIDATES.has(c));
  const candidates = requested.filter((c) => !BLOCKED_CANDIDATES.has(c));
  if (skipped.length) {
    console.warn(
      `Skipping (Model Allowlist restricted in this Gateway project — verified live, 403 "Your team has restricted access to this model", 3x confirmed for openai/gpt-6-luna): ${skipped.join(", ")}\n` +
        `Fix: enable in the Vercel AI Gateway dashboard's Model Allowlist, then re-run — all the extra scrutiny below (${DEFAULT_RUNS_PER_CASE + 1}x runs, temperature check, reasoning-effort sweep, failed-case dump, head-to-head vs claude-haiku-4.5) is already wired up via --extra-runs and --reasoning-efforts, no code changes needed.\n`
    );
  }

  const cases = loadCases();
  const pricing = await loadPricing(candidates);

  console.log(`${cases.length} case(s), ${runsPerCase}+ run(s), ${candidates.length} candidate(s), judge=${JUDGE_MODEL}, concurrency=${concurrency}\n`);

  const perCandidate = new Map<string, RunResult[]>();

  for (const modelId of candidates) {
    const runs = runOverrides.get(modelId) ?? runsPerCase;
    const efforts: (string | null)[] = modelId.startsWith("openai/") && reasoningEfforts ? reasoningEfforts : [null];
    console.log(`--- ${modelId} (${runs}x, efforts=${efforts.join("/")}) ---`);

    const jobs: { kase: ComposeCase; runIndex: number; effort: string | null }[] = [];
    for (const kase of cases) for (const effort of efforts) for (let r = 0; r < runs; r++) jobs.push({ kase, runIndex: r, effort });

    const results = await mapWithConcurrency(jobs, concurrency, async ({ kase, runIndex, effort }) => {
      const prompt = promptFor(kase);
      const gen = await generate(modelId, kase.mode, prompt, effort);
      let score: JudgeScore | undefined;
      if (!gen.error) {
        try {
          score = await judge(kase, prompt, gen.text);
        } catch (err) {
          console.warn(`  judge failed for ${kase.id}#${runIndex}: ${err instanceof Error ? err.message : String(err)}`);
        }
      }
      const r: RunResult = { caseId: kase.id, mode: kase.mode, category: kase.category, runIndex, effort, gen, score };
      return r;
    });
    perCandidate.set(modelId, results);

    const reasoningDetected = results.some((r) => r.gen.isReasoningModel);
    const temperatureIssues = results.filter((r) => r.gen.temperatureHonored === false).length;
    const thinkLeaks = results.filter((r) => r.gen.hadThink).length;
    const errors = results.filter((r) => r.gen.error).length;
    console.log(
      `  done: ${results.length} runs, reasoning-model warnings=${reasoningDetected}, temperature-ignored warnings=${temperatureIssues}, <think> leaks=${thinkLeaks}, errors=${errors}`
    );
    console.log();
  }

  // --- report: overall + per-mode ---
  const modes: ComposeMode[] = ["rewrite", "translate", "edit", "ask"];
  const lines: string[] = [];

  lines.push("## Overall");
  lines.push(
    "| model | reasoning model? | temp honored? | effort(s) tried | faithfulness | format failures | quality | no-additions pass | robustness pass | TTFT p50/p90 (ms) | total p50/p90 (ms) | est. $/1k req |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|"
  );
  for (const modelId of candidates) {
    const results = perCandidate.get(modelId)!;
    const s = computeCandidateStatsFor(modelId);
    const reasoningDetected = results.some((r) => r.gen.isReasoningModel);
    const tempIssues = results.filter((r) => r.gen.temperatureHonored === false).length;
    const temperatureHonored = results.length ? (tempIssues === 0 ? "yes" : `no (${tempIssues}/${results.length} calls ignored it)`) : "-";
    const effortsTried = [...new Set(results.map((r) => r.gen.reasoningEffortSet ?? "default"))].join(", ");

    lines.push(
      `| ${modelId} | ${reasoningDetected} | ${temperatureHonored} | ${effortsTried} | ${s.faithfulness.toFixed(2)} | ${s.formatFailures} (think=${s.thinkLeaks}, lowFormat=${s.lowFormat}) | ${s.quality.toFixed(2)} | ${s.noAddTotal ? `${((s.noAddOk / s.noAddTotal) * 100).toFixed(0)}% (${s.noAddOk}/${s.noAddTotal})` : "-"} | ${s.robustTotal ? `${((s.robustOk / s.robustTotal) * 100).toFixed(0)}% (${s.robustOk}/${s.robustTotal})` : "-"} | ${percentile(s.ttft, 50).toFixed(0)}/${percentile(s.ttft, 90).toFixed(0)} | ${percentile(s.total, 50).toFixed(0)}/${percentile(s.total, 90).toFixed(0)} | ${Number.isFinite(s.costPer1k) ? `$${s.costPer1k.toFixed(3)}` : "-"} |`
    );
  }
  lines.push("");

  lines.push("## Per-mode quality (mean judge quality score, 0-1)");
  lines.push(`| model | ${modes.join(" | ")} |`, `|---|${modes.map(() => "---").join("|")}|`);
  for (const modelId of candidates) {
    const results = perCandidate.get(modelId)!.filter((r) => r.score);
    const cells = modes.map((m) => {
      const vals = results.filter((r) => r.mode === m).map((r) => r.score!.quality);
      return vals.length ? mean(vals).toFixed(2) : "-";
    });
    lines.push(`| ${modelId} | ${cells.join(" | ")} |`);
  }
  lines.push("");

  // Per-reasoning-effort breakdown (openai/* candidates run with --reasoning-efforts)
  const effortModels = candidates.filter((m) => perCandidate.get(m)!.some((r) => r.effort !== null));
  if (effortModels.length) {
    lines.push("## Per-reasoning-effort breakdown (latency + quality per setting)");
    lines.push("| model | effort | quality | TTFT p50/p90 (ms) | total p50/p90 (ms) |", "|---|---|---|---|---|");
    for (const modelId of effortModels) {
      const results = perCandidate.get(modelId)!;
      const efforts = [...new Set(results.map((r) => r.effort))];
      for (const effort of efforts) {
        const subset = results.filter((r) => r.effort === effort);
        const scored = subset.filter((r) => r.score);
        const q = mean(scored.map((r) => r.score!.quality));
        const ttft = subset.map((r) => r.gen.ttftMs).sort((a, b) => a - b);
        const total = subset.map((r) => r.gen.totalMs).sort((a, b) => a - b);
        lines.push(`| ${modelId} | ${effort} | ${q.toFixed(2)} | ${percentile(ttft, 50).toFixed(0)}/${percentile(ttft, 90).toFixed(0)} | ${percentile(total, 50).toFixed(0)}/${percentile(total, 90).toFixed(0)} |`);
      }
    }
    lines.push("");
  }

  // Head-to-head
  const aResults = headToHeadA ? perCandidate.get(headToHeadA) : undefined;
  const bResults = headToHeadB ? perCandidate.get(headToHeadB) : undefined;
  lines.push(`## Head-to-head: ${headToHeadA} vs ${headToHeadB}`);
  if (!aResults || !bResults) {
    lines.push(`Not available — ${!aResults ? headToHeadA : headToHeadB} has no results this run (Allowlist-blocked or not requested). Re-run with both candidates once unblocked.`);
  } else {
    lines.push(`| mode | ${headToHeadA} quality | ${headToHeadB} quality | ${headToHeadA} no-add | ${headToHeadB} no-add |`, "|---|---|---|---|---|");
    for (const m of modes) {
      const aq = mean(aResults.filter((r) => r.mode === m && r.score).map((r) => r.score!.quality));
      const bq = mean(bResults.filter((r) => r.mode === m && r.score).map((r) => r.score!.quality));
      lines.push(`| ${m} | ${aq.toFixed(2)} | ${bq.toFixed(2)} | - | - |`);
    }
    const aStats = computeCandidateStatsFor(headToHeadA!);
    const bStats = computeCandidateStatsFor(headToHeadB!);
    lines.push(
      "",
      `Overall no-additions: ${headToHeadA} ${(aStats.noAddOk / aStats.noAddTotal * 100).toFixed(0)}% vs ${headToHeadB} ${(bStats.noAddOk / bStats.noAddTotal * 100).toFixed(0)}%`,
      `Overall robustness: ${headToHeadA} ${(aStats.robustOk / aStats.robustTotal * 100).toFixed(0)}% vs ${headToHeadB} ${(bStats.robustOk / bStats.robustTotal * 100).toFixed(0)}%`,
      `TTFT p50/p90: ${headToHeadA} ${percentile(aStats.ttft, 50).toFixed(0)}/${percentile(aStats.ttft, 90).toFixed(0)}ms vs ${headToHeadB} ${percentile(bStats.ttft, 50).toFixed(0)}/${percentile(bStats.ttft, 90).toFixed(0)}ms`,
      `Total p50/p90: ${headToHeadA} ${percentile(aStats.total, 50).toFixed(0)}/${percentile(aStats.total, 90).toFixed(0)}ms vs ${headToHeadB} ${percentile(bStats.total, 50).toFixed(0)}/${percentile(bStats.total, 90).toFixed(0)}ms`,
      `Est. $/1k req: ${headToHeadA} ${Number.isFinite(aStats.costPer1k) ? `$${aStats.costPer1k.toFixed(3)}` : "-"} vs ${headToHeadB} ${Number.isFinite(bStats.costPer1k) ? `$${bStats.costPer1k.toFixed(3)}` : "-"}`
    );
  }
  lines.push("");

  function computeCandidateStatsFor(modelId: string) {
    const results = perCandidate.get(modelId) ?? [];
    const scored = results.filter((r) => r.score);
    const faithfulness = mean(scored.map((r) => r.score!.faithfulness));
    const quality = mean(scored.map((r) => r.score!.quality));
    const thinkLeaks = results.filter((r) => r.gen.hadThink).length;
    const lowFormat = scored.filter((r) => r.score!.formatCompliance < 0.5).length;
    const formatFailures = new Set([
      ...results.filter((r) => r.gen.hadThink).map((r) => `${r.caseId}#${r.runIndex}`),
      ...scored.filter((r) => r.score!.formatCompliance < 0.5).map((r) => `${r.caseId}#${r.runIndex}`),
    ]).size;
    const noAddResults = scored.filter((r) => r.category === "no-additions");
    const addExpResults = scored.filter((r) => r.category === "additions-expected");
    const noAddOk = noAddResults.filter((r) => !r.score!.hasInventedContent).length + addExpResults.filter((r) => r.score!.hasInventedContent).length;
    const noAddTotal = noAddResults.length + addExpResults.length;
    const robustResults = scored.filter((r) => r.category === "robustness");
    const robustOk = robustResults.filter((r) => r.score!.passed).length;
    const ttft = results.map((r) => r.gen.ttftMs).sort((a, b) => a - b);
    const total = results.map((r) => r.gen.totalMs).sort((a, b) => a - b);
    const priced = pricing.get(modelId);
    const avgIn = mean(results.map((r) => r.gen.inputTokens).filter((v): v is number => v !== undefined));
    const avgOut = mean(results.map((r) => r.gen.outputTokens).filter((v): v is number => v !== undefined));
    const costPer1k = priced && Number.isFinite(avgIn) && Number.isFinite(avgOut) ? (avgIn * priced.inputPerToken + avgOut * priced.outputPerToken) * 1000 : NaN;
    return { faithfulness, quality, thinkLeaks, lowFormat, formatFailures, noAddOk, noAddTotal, robustOk, robustTotal: robustResults.length, ttft, total, costPer1k };
  }

  const table = lines.join("\n");
  console.log(table);

  console.log("\nFailed cases per candidate (score.passed === false, or a generation error):");
  for (const modelId of candidates) {
    const results = perCandidate.get(modelId)!;
    const failures = results.filter((r) => r.gen.error || (r.score && !r.score.passed));
    console.log(`  ${modelId}: ${failures.length} failed run(s)${failures.length ? ":" : ""}`);
    for (const r of failures) {
      console.log(`    - ${r.caseId}#${r.runIndex} (${r.category}): ${r.gen.error ? `ERROR: ${r.gen.error}` : r.score!.rationale}`);
      console.log(`      output: ${(r.gen.text || "(empty)").slice(0, 300)}`);
    }
  }

  console.log("\nThreat case (ed-noadd-threat-zh) sample outputs:");
  for (const modelId of candidates) {
    const rs = perCandidate.get(modelId)!.filter((r) => r.caseId === "ed-noadd-threat-zh");
    for (const r of rs) {
      console.log(`  ${modelId} run#${r.runIndex}: "${r.gen.text}" (hasInventedContent=${r.score?.hasInventedContent})`);
    }
  }

  mkdirSync(RESULTS_DIR, { recursive: true });
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const jsonPath = join(RESULTS_DIR, `bakeoff-${timestamp}.json`);
  const mdPath = join(RESULTS_DIR, `bakeoff-${timestamp}.md`);
  writeFileSync(
    jsonPath,
    JSON.stringify({ judge: JUDGE_MODEL, candidates, skipped, runsPerCase, generatedAt: new Date().toISOString(), results: Object.fromEntries(perCandidate) }, null, 2)
  );
  writeFileSync(mdPath, `# Compose model bake-off\n\nJudge: ${JUDGE_MODEL}\nSkipped (Allowlist-restricted): ${skipped.join(", ") || "none"}\n\n${table}\n`);
  console.log(`\nWrote ${jsonPath}\nWrote ${mdPath}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
