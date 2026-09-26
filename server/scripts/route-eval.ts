#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * Live calibration for POST /api/route's Jev-based auto-mode router.
 *
 * Runs every case in eval/route-cases.json through `routeTranscript()`
 * (lib/router.ts — the exact same code the route handler uses) against the
 * real Gateway, and reports:
 *   - accuracy: needsCloud prediction matches the hand-labelled expectation
 *   - false-clean rate: of the cases that SHOULD go to cloud (fillers,
 *     corrections, lists, garbled/misheard text), the fraction the router
 *     said were clean. This is the costly error — inserting bad text
 *     as-is — and should be ~0.
 *   - false-messy rate: of the cases that ARE clean, the fraction the
 *     router sent to cloud anyway. Cheap error (one extra SMART round
 *     trip), reported for completeness.
 *   - latency p50/p90 (lib/router.ts's own latencyMs per case).
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

import { routeTranscript, type RouteReason } from "../lib/router";

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
  latencyMs: number;
  correct: boolean;
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

  console.log(`Running ${cases.length} case(s) against the real Gateway (typesafe-ai/jev)...\n`);

  const results: Result[] = [];
  for (const kase of cases) {
    const decision = await routeTranscript({
      transcript: kase.transcript,
      vocabulary: kase.vocabulary,
      languageHints: kase.languageHints,
    });
    const correct = decision.needsCloud === kase.expectedNeedsCloud;
    results.push({ kase, ...decision, correct });
    const p = decision.cleanProbability !== null ? decision.cleanProbability.toFixed(2) : "-";
    console.log(
      `${(correct ? "OK  " : "MISS")} ${kase.id.padEnd(20)} expected=${String(kase.expectedNeedsCloud).padEnd(5)} got=${String(
        decision.needsCloud
      ).padEnd(5)} p=${p.padStart(5)} reason=${decision.reason.padEnd(18)} ${decision.latencyMs}ms`
    );
  }

  const total = results.length;
  const correctCount = results.filter((r) => r.correct).length;
  const accuracy = total ? correctCount / total : NaN;

  const shouldGoCloud = results.filter((r) => r.kase.expectedNeedsCloud);
  const falseClean = shouldGoCloud.filter((r) => !r.needsCloud);
  const falseCleanRate = shouldGoCloud.length ? falseClean.length / shouldGoCloud.length : NaN;

  const shouldBeClean = results.filter((r) => !r.kase.expectedNeedsCloud);
  const falseMessy = shouldBeClean.filter((r) => r.needsCloud);
  const falseMessyRate = shouldBeClean.length ? falseMessy.length / shouldBeClean.length : NaN;

  const latencies = results.map((r) => r.latencyMs).sort((a, b) => a - b);
  const p50 = percentile(latencies, 50);
  const p90 = percentile(latencies, 90);

  console.log(`\n${correctCount}/${total} correct (accuracy=${(accuracy * 100).toFixed(1)}%)`);
  console.log(
    `false-clean rate (costly — inserted bad text as-is): ${falseClean.length}/${shouldGoCloud.length} = ${(falseCleanRate * 100).toFixed(1)}%`
  );
  console.log(
    `false-messy rate (cheap — sent clean text to cloud): ${falseMessy.length}/${shouldBeClean.length} = ${(falseMessyRate * 100).toFixed(1)}%`
  );
  console.log(`latency: p50=${p50.toFixed(0)}ms p90=${p90.toFixed(0)}ms min=${latencies[0]?.toFixed(0)}ms max=${latencies[latencies.length - 1]?.toFixed(0)}ms`);

  if (falseClean.length > 0) {
    console.log("\nFalse-clean cases (router said clean, should have gone to cloud):");
    for (const r of falseClean) {
      console.log(`  - ${r.kase.id}: "${r.kase.transcript}"  (p=${r.cleanProbability?.toFixed(2)}, ${r.kase.note ?? ""})`);
    }
  }
  if (falseMessy.length > 0) {
    console.log("\nFalse-messy cases (router sent clean text to cloud):");
    for (const r of falseMessy) {
      console.log(`  - ${r.kase.id}: "${r.kase.transcript}"  (p=${r.cleanProbability?.toFixed(2)}, reason=${r.reason})`);
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
