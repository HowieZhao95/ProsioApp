#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * Live calibration for POST /api/transcribe's P1.2 combined local-transcript
 * check (`checkLocalTranscript`, lib/transcribe-routing.ts) — the single
 * Jev `evaluate()` call that decides BOTH whether a local transcript is
 * clean enough to skip Gemini and what the user wants done with it. This
 * used to test `routeTranscript()` (the plain 2-question `/api/route` call)
 * directly; it's now switched to the 3-question combined call so this eval
 * validates the exact code path production actually uses for the
 * local-transcript fast path (docs/P1.2-AUDIO-ROUTING.md §3).
 *
 * `eval/route-cases.json` has no `hasSelection` field (it predates the
 * intent question) — every case is run with `hasSelection: false`, which
 * only affects which intent criterion is offered (`dictate` vs `edit`) and
 * not the clean/recognized questions this script cares about.
 *
 * Reports:
 *   - Per-case results at the combined check's OWN production threshold
 *     (`LOCAL_TEXT_CLEAN_THRESHOLD = 0.9`, stricter than `/api/route`'s
 *     0.8 — see lib/transcribe-routing.ts for why): accuracy, false-clean
 *     rate (costly — inserts bad text with zero cloud correction, should
 *     be ~0), false-messy rate (cheap), latency p50/p90.
 *   - A threshold sweep at 0.8/0.85/0.9/0.95, recomputed from each case's
 *     raw `cleanProbability` (no extra Jev calls) — per the coordinator's
 *     request, to see whether the threshold could be safely lowered.
 *   - Jev-availability status: if the shared circuit breaker (lib/jev.ts)
 *     opens partway through (a real failure, or the currently-known
 *     GatewayRateLimitError "high demand" condition), remaining cases
 *     return `cleanProbability: null` immediately — this is reported
 *     explicitly rather than silently degrading the accuracy numbers.
 *
 * Usage (from server/):
 *   npx tsx --env-file=../.env.local scripts/route-eval.ts
 *   npx tsx --env-file=../.env.local scripts/route-eval.ts --case filler-zh-01
 *
 * Requires AI_GATEWAY_API_KEY.
 */

import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

import { decideRoute, type RouteReason } from "../lib/router";
import { checkLocalTranscript, LOCAL_TEXT_CLEAN_THRESHOLD } from "../lib/transcribe-routing";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EVAL_DIR = resolve(__dirname, "../../eval");
const CASES_PATH = join(EVAL_DIR, "route-cases.json");

const caseSchema = z.object({
  id: z.string(),
  language: z.enum(["zh", "en", "mixed"]),
  transcript: z.string().min(1),
  vocabulary: z.array(z.string()).default([]),
  languageHints: z.array(z.string()).default([]),
  expectedNeedsCloud: z.boolean(),
  note: z.string().optional(),
});
type RouteCase = z.infer<typeof caseSchema>;
const casesSchema = z.array(caseSchema);

function loadCases(): RouteCase[] {
  const raw = JSON.parse(readFileSync(CASES_PATH, "utf8"));
  const parsed = casesSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(`eval/route-cases.json failed validation:\n${parsed.error.message}`);
    process.exit(1);
  }
  return parsed.data;
}

function percentile(sorted: number[], p: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[idx]!;
}

interface Result {
  kase: RouteCase;
  needsCloud: boolean;
  cleanProbability: number | null;
  reason: RouteReason;
  intent: string | null;
  latencyMs: number;
  correct: boolean;
}

const SWEEP_THRESHOLDS = [0.8, 0.85, 0.9, 0.95];

function reportAt(label: string, results: Result[], threshold: number): void {
  // Only cases where Jev actually answered (cleanProbability !== null) can
  // be recomputed at a different threshold.
  const answered = results.filter((r) => r.cleanProbability !== null);
  const recomputed = answered.map((r) => {
    const { needsCloud } = decideRoute(r.cleanProbability!, r.cleanProbability!, threshold); // recognizedProbability isn't tracked separately here — see header comment; only needsCloud (not the reason tie-break) is used below
    return { ...r, needsCloud };
  });

  const shouldGoCloud = recomputed.filter((r) => r.kase.expectedNeedsCloud);
  const falseClean = shouldGoCloud.filter((r) => !r.needsCloud);
  const falseCleanRate = shouldGoCloud.length ? falseClean.length / shouldGoCloud.length : NaN;

  const shouldBeClean = recomputed.filter((r) => !r.kase.expectedNeedsCloud);
  const falseMessy = shouldBeClean.filter((r) => r.needsCloud);
  const falseMessyRate = shouldBeClean.length ? falseMessy.length / shouldBeClean.length : NaN;

  const correctCount = recomputed.filter((r) => r.needsCloud === r.kase.expectedNeedsCloud).length;
  const accuracy = recomputed.length ? correctCount / recomputed.length : NaN;

  console.log(
    `  ${label.padEnd(12)} n=${recomputed.length.toString().padEnd(3)} accuracy=${(accuracy * 100).toFixed(1).padStart(5)}%  ` +
      `false-clean=${falseClean.length}/${shouldGoCloud.length}=${(falseCleanRate * 100).toFixed(1).padStart(5)}%  ` +
      `false-messy=${falseMessy.length}/${shouldBeClean.length}=${(falseMessyRate * 100).toFixed(1).padStart(5)}%`
  );
}

async function main(): Promise<void> {
  if (!process.env.AI_GATEWAY_API_KEY) {
    console.error("AI_GATEWAY_API_KEY is not set. Run with --env-file=../.env.local (see the shebang) or export it.");
    process.exit(1);
  }

  const caseIdArg = process.argv.includes("--case") ? process.argv[process.argv.indexOf("--case") + 1] : undefined;
  const allCases = loadCases();
  const cases = caseIdArg ? allCases.filter((c) => c.id === caseIdArg) : allCases;
  if (caseIdArg && cases.length === 0) {
    console.error(`No case with id "${caseIdArg}"`);
    process.exit(1);
  }

  console.log(
    `Running ${cases.length} case(s) against the real Gateway (typesafe-ai/jev, combined route+intent call, hasSelection=false for all)...\n`
  );

  const results: Result[] = [];
  for (const kase of cases) {
    const decision = await checkLocalTranscript({
      transcript: kase.transcript,
      vocabulary: kase.vocabulary,
      languageHints: kase.languageHints,
      hasSelection: false,
    });
    const correct = decision.needsCloud === kase.expectedNeedsCloud;
    results.push({
      kase,
      needsCloud: decision.needsCloud,
      cleanProbability: decision.cleanProbability,
      reason: decision.reason,
      intent: decision.intent,
      latencyMs: decision.latencyMs,
      correct,
    });
    const p = decision.cleanProbability !== null ? decision.cleanProbability.toFixed(2) : "-";
    console.log(
      `${correct ? "OK  " : "MISS"} ${kase.id.padEnd(20)} expected=${String(kase.expectedNeedsCloud).padEnd(5)} got=${String(
        decision.needsCloud
      ).padEnd(5)} p=${p.padStart(5)} intent=${String(decision.intent).padEnd(9)} reason=${decision.reason.padEnd(18)} ${decision.latencyMs}ms`
    );
  }

  const total = results.length;
  const unavailable = results.filter((r) => r.cleanProbability === null);

  if (unavailable.length === total) {
    console.log(
      "\nJev is unavailable for EVERY case in this run (likely the known GatewayRateLimitError \"high demand\" " +
        "condition, or the circuit breaker opened after the very first call and stayed open for the rest of the " +
        `run — cooldown is ${60}s). No accuracy/threshold numbers are meaningful here; re-run once Jev responds.`
    );
    return;
  }
  if (unavailable.length > 0) {
    console.log(
      `\nNote: Jev was unavailable for ${unavailable.length}/${total} cases (likely the circuit breaker opening ` +
        "after a failure partway through this run, per lib/jev.ts). The numbers below are computed only over the " +
        `${total - unavailable.length} cases that got a real answer.`
    );
  }

  const answered = results.filter((r) => r.cleanProbability !== null);
  const correctCount = answered.filter((r) => r.correct).length;
  const accuracy = answered.length ? correctCount / answered.length : NaN;

  const shouldGoCloud = answered.filter((r) => r.kase.expectedNeedsCloud);
  const falseClean = shouldGoCloud.filter((r) => !r.needsCloud);
  const falseCleanRate = shouldGoCloud.length ? falseClean.length / shouldGoCloud.length : NaN;

  const shouldBeClean = answered.filter((r) => !r.kase.expectedNeedsCloud);
  const falseMessy = shouldBeClean.filter((r) => r.needsCloud);
  const falseMessyRate = shouldBeClean.length ? falseMessy.length / shouldBeClean.length : NaN;

  const latencies = answered.map((r) => r.latencyMs).sort((a, b) => a - b);
  const p50 = percentile(latencies, 50);
  const p90 = percentile(latencies, 90);

  console.log(`\nAt the combined check's production threshold (${LOCAL_TEXT_CLEAN_THRESHOLD}):`);
  console.log(`  ${correctCount}/${answered.length} correct (accuracy=${(accuracy * 100).toFixed(1)}%)`);
  console.log(
    `  false-clean rate (costly — inserted bad text as-is, no Gemini correction): ${falseClean.length}/${shouldGoCloud.length} = ${(falseCleanRate * 100).toFixed(1)}%`
  );
  console.log(
    `  false-messy rate (cheap — sent clean text to Gemini anyway): ${falseMessy.length}/${shouldBeClean.length} = ${(falseMessyRate * 100).toFixed(1)}%`
  );
  if (latencies.length > 0) {
    console.log(
      `  latency: p50=${p50.toFixed(0)}ms p90=${p90.toFixed(0)}ms min=${latencies[0]?.toFixed(0)}ms max=${latencies[latencies.length - 1]?.toFixed(0)}ms`
    );
  }

  console.log(`\nThreshold sweep (recomputed from raw cleanProbability, no extra Jev calls):`);
  for (const threshold of SWEEP_THRESHOLDS) {
    reportAt(`>= ${threshold}`, answered, threshold);
  }

  if (falseClean.length > 0) {
    console.log("\nFalse-clean cases at the production threshold (said clean, should have gone to cloud):");
    for (const r of falseClean) {
      console.log(`  - ${r.kase.id}: "${r.kase.transcript}"  (p=${r.cleanProbability?.toFixed(2)}, ${r.kase.note ?? ""})`);
    }
  }
  if (falseMessy.length > 0) {
    console.log("\nFalse-messy cases at the production threshold (sent clean text to cloud):");
    for (const r of falseMessy) {
      console.log(`  - ${r.kase.id}: "${r.kase.transcript}"  (p=${r.cleanProbability?.toFixed(2)}, reason=${r.reason})`);
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
