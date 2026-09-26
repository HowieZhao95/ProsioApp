#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * Calibration for POST /api/intent (lib/intent.ts, Jev-based) plus a
 * scripts-only, non-authoritative comparison against a TS port of the
 * client's bilingual (zh/en) fallback rules (scripts/intent-rules.ts —
 * see that file's header: it is NOT the real client rules, which live in
 * ProsioCore/Swift).
 *
 * Runs every case in eval/intent-cases.json through three "sources":
 *   - jev:   classifyIntent() (lib/intent.ts) against the real Gateway.
 *   - rules: classifyIntentByRules() (scripts/intent-rules.ts), no network.
 *   - chain: jev's answer, but whenever jev reports source "unavailable"
 *            (error/timeout), falls back to rules — mirroring what the
 *            client actually does per the amended docs/PROMPTS.md §5b.
 *            (Note: a below-threshold jev answer is NOT replaced by rules
 *            here, since source is still "jev" in that case and the client
 *            does not invoke the rules fallback then either.)
 *
 * Reports per source: accuracy, confusion matrix, false-command rate on
 * dictate cases (dictate cases misclassified as edit/ask/translate — the
 * costly error, should be ~0), and (jev only) latency p50/p90 plus a
 * threshold sweep (0.5-0.9) recomputed from the raw confidence.
 *
 * Usage (from server/):
 *   npx tsx --env-file=../.env.local scripts/intent-eval.ts
 *   npx tsx --env-file=../.env.local scripts/intent-eval.ts --case ask-zh-cue-01
 *   npx tsx --env-file=../.env.local scripts/intent-eval.ts --rules-only
 *
 * Requires AI_GATEWAY_API_KEY for the jev/chain sources; --rules-only needs
 * no network and no key. Jev may currently fail with GatewayRateLimitError
 * ("upstream provider ... high demand") — the script degrades gracefully:
 * every failed jev call is just another "unavailable" data point (correctly
 * scored as incorrect against a non-null expectation), and the summary
 * prints how many calls errored so a fully-blocked run is obvious rather
 * than silently reported as low accuracy.
 */

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

import { classifyIntent, INTENT_CONFIDENCE_THRESHOLD, type IntentValue } from "../lib/intent";
import { classifyIntentByRules } from "./intent-rules";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EVAL_DIR = resolve(__dirname, "../../eval");
const CASES_PATH = join(EVAL_DIR, "intent-cases.json");

const caseSchema = z.object({
  id: z.string(),
  language: z.enum(["en", "zh", "ja", "es", "fr", "ko", "mixed"]),
  hasSelection: z.boolean(),
  transcript: z.string().min(1),
  expected: z.enum(["dictate", "edit", "ask", "translate"]),
  note: z.string().optional(),
});
type IntentCase = z.infer<typeof caseSchema>;
const casesSchema = z.array(caseSchema);

function loadCases(): IntentCase[] {
  const raw = JSON.parse(readFileSync(CASES_PATH, "utf8"));
  const parsed = casesSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(`eval/intent-cases.json failed validation:\n${parsed.error.message}`);
    process.exit(1);
  }
  return parsed.data;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx]!;
}

type Source = "jev" | "rules" | "chain";

interface CaseResult {
  kase: IntentCase;
  predicted: IntentValue | null; // null only possible for jev when unavailable
  confidence: number | null;
  jevSource: "jev" | "unavailable" | null; // raw jev source, for chain/threshold-sweep bookkeeping
  latencyMs: number | null;
}

function isCorrect(predicted: IntentValue | null, expected: IntentValue): boolean {
  return predicted === expected;
}

function summarize(source: Source, results: CaseResult[]): void {
  const total = results.length;
  const correct = results.filter((r) => isCorrect(r.predicted, r.kase.expected)).length;
  const accuracy = total ? correct / total : NaN;

  console.log(`\n=== ${source} ===`);
  console.log(`${correct}/${total} correct (accuracy=${(accuracy * 100).toFixed(1)}%)`);

  if (source === "jev" || source === "chain") {
    const unavailable = results.filter((r) => r.predicted === null).length;
    if (unavailable > 0) {
      console.log(`  (${unavailable}/${total} calls returned "unavailable" — Jev errored, timed out, or is rate-limited)`);
    }
  }

  // Confusion matrix.
  const intents: IntentValue[] = ["dictate", "edit", "ask", "translate"];
  const matrix: Record<string, Record<string, number>> = {};
  for (const exp of intents) matrix[exp] = Object.fromEntries(intents.map((i) => [i, 0]));
  for (const r of results) {
    if (r.predicted === null) continue;
    matrix[r.kase.expected]![r.predicted] = (matrix[r.kase.expected]![r.predicted] ?? 0) + 1;
  }
  console.log("  confusion matrix (rows=expected, cols=predicted; excludes 'unavailable'):");
  console.log(`    ${"".padEnd(11)}${intents.map((i) => i.padEnd(11)).join("")}`);
  for (const exp of intents) {
    console.log(`    ${exp.padEnd(11)}${intents.map((i) => String(matrix[exp]![i]).padEnd(11)).join("")}`);
  }

  // False-command rate: dictate cases misclassified as edit/ask/translate.
  const dictateCases = results.filter((r) => r.kase.expected === "dictate");
  const falseCommands = dictateCases.filter((r) => r.predicted !== null && r.predicted !== "dictate");
  const falseCommandRate = dictateCases.length ? falseCommands.length / dictateCases.length : NaN;
  console.log(
    `  false-command rate on dictate cases (should be ~0): ${falseCommands.length}/${dictateCases.length} = ${(falseCommandRate * 100).toFixed(1)}%`
  );
  if (falseCommands.length > 0) {
    for (const r of falseCommands) {
      console.log(`    - ${r.kase.id}: "${r.kase.transcript}" -> ${r.predicted} (expected dictate)`);
    }
  }

  if (source === "jev") {
    const latencies = results.map((r) => r.latencyMs).filter((l): l is number => l !== null).sort((a, b) => a - b);
    if (latencies.length > 0) {
      const p50 = percentile(latencies, 50);
      const p90 = percentile(latencies, 90);
      console.log(`  latency: p50=${p50.toFixed(0)}ms p90=${p90.toFixed(0)}ms min=${latencies[0]!.toFixed(0)}ms max=${latencies[latencies.length - 1]!.toFixed(0)}ms`);
    }

    // Threshold sweep, recomputed from raw confidence (only for cases where
    // jev actually answered — "unavailable" cases have no confidence and
    // are excluded, matching production behavior where they never reach
    // the threshold check).
    console.log("  threshold sweep (recomputed from raw jev confidence):");
    for (const threshold of [0.5, 0.6, 0.7, 0.8, 0.9]) {
      let ok = 0;
      let n = 0;
      for (const r of results) {
        if (r.confidence === null || r.jevSource !== "jev") continue;
        n++;
        // We don't have jev's raw top-choice label when it was below the
        // *production* threshold and got defaulted — but classifyIntent
        // returns intent=default in that case regardless of the swept
        // threshold. To properly sweep we'd need the raw top choice; as a
        // conservative proxy, treat "confidence >= threshold" as "trust
        // the reported intent field", else "trust the default for
        // hasSelection". This slightly under-counts recovery of high
        // (>=0.7) confidence answers that were already correct, but never
        // over-counts correctness.
        const predicted = r.confidence >= threshold ? r.predicted : r.kase.hasSelection ? "edit" : "dictate";
        if (predicted === r.kase.expected) ok++;
      }
      console.log(`    >= ${threshold.toFixed(1)}: ${ok}/${n} = ${n ? ((ok / n) * 100).toFixed(1) : "n/a"}%`);
    }
  }
}

async function main(): Promise<void> {
  const caseIdArg = process.argv.includes("--case") ? process.argv[process.argv.indexOf("--case") + 1] : undefined;
  const rulesOnly = process.argv.includes("--rules-only");

  const allCases = loadCases();
  const cases = caseIdArg ? allCases.filter((c) => c.id === caseIdArg) : allCases;
  if (caseIdArg && cases.length === 0) {
    console.error(`No case with id "${caseIdArg}"`);
    process.exit(1);
  }

  const hasKey = Boolean(process.env.AI_GATEWAY_API_KEY);
  if (!rulesOnly && !hasKey) {
    console.log("AI_GATEWAY_API_KEY is not set — running --rules-only (no network, no key needed).");
  }
  const runJev = !rulesOnly && hasKey;

  console.log(`Running ${cases.length} case(s)${runJev ? " against the real Gateway (typesafe-ai/jev) and the rules port" : " through the rules port only"}...`);

  const rulesResults: CaseResult[] = [];
  const jevResults: CaseResult[] = [];
  const chainResults: CaseResult[] = [];

  for (const kase of cases) {
    const rulesDecision = classifyIntentByRules({ transcript: kase.transcript, hasSelection: kase.hasSelection });
    rulesResults.push({ kase, predicted: rulesDecision.intent, confidence: null, jevSource: null, latencyMs: null });

    if (runJev) {
      const decision = await classifyIntent({ transcript: kase.transcript, hasSelection: kase.hasSelection });
      jevResults.push({ kase, predicted: decision.intent, confidence: decision.confidence, jevSource: decision.source, latencyMs: decision.latencyMs });

      const chainPredicted = decision.source === "unavailable" ? rulesDecision.intent : decision.intent;
      chainResults.push({ kase, predicted: chainPredicted, confidence: decision.confidence, jevSource: decision.source, latencyMs: decision.latencyMs });

      const status = decision.source === "unavailable" ? "UNAVAILABLE" : isCorrect(decision.intent, kase.expected) ? "OK  " : "MISS";
      console.log(
        `  jev   ${status} ${kase.id.padEnd(22)} expected=${kase.expected.padEnd(10)} got=${String(decision.intent).padEnd(10)} conf=${
          decision.confidence !== null ? decision.confidence.toFixed(2) : "-   "
        } ${decision.latencyMs}ms`
      );
    }
  }

  if (runJev) {
    summarize("jev", jevResults);
    summarize("chain", chainResults);
  } else {
    console.log(
      "\nJev was not run (no AI_GATEWAY_API_KEY, or --rules-only). If this is unexpected: Jev may currently be rate-limited " +
        '(GatewayRateLimitError, "upstream provider ... high demand") per the coordinator\'s note — set the key and re-run to check.'
    );
  }
  summarize("rules", rulesResults);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
