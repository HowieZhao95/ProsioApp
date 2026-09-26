#!/usr/bin/env -S npx tsx --env-file=../.env.local
/**
 * SMART transcription formatting eval — how consistently does
 * `gemini-3.5-transcribe` (SMART mode) emit Markdown lists for spoken
 * lists, per the P1.2.1 auto-formatting task (coordinator: "I verified
 * Gemini SMART already emits Markdown lists... '以下几个要点。第一…第二…' ->
 * '1. …' lines; English 'first… second…' -> '- ' bullets").
 *
 * Generates ~17 zh/en/mixed test clips with macOS `say` (Tingting for
 * zh/mixed, Samantha for en) piped through `afconvert -f WAVE -d
 * LEI16@16000 -c 1` (Gemini's required format), transcribes each via
 * `transcribeBatch()` (lib/gateway.ts, SMART mode — the exact function
 * POST /api/transcribe uses), then runs the SAME post-processing pipeline
 * POST /api/transcribe's cloud path does: `normalizeListMarkers()`
 * (lib/text-format.ts) followed by `repairListFormatting()`
 * (lib/list-repair.ts, docs/PROMPTS.md §1b — the P1.2.1 follow-up that
 * repairs the mixed zh/en implicit-list gap this eval originally found).
 * Reports per case:
 *   - listDetected: does the FINAL (post-repair) transcript contain
 *     Markdown list lines?
 *   - style: "bullet" ("- "), "numbered" ("1. "), "mixed", or "none"
 *   - leadInOnOwnLine: is there a non-list lead-in line before the list
 *     (docs/PROMPTS.md's Rewrite rule expects this)?
 *   - formatRepair: "applied" | "rejected" | "timeout" | null (the repair
 *     step's own outcome for this case) and its added latency.
 *   - a summary of consistency across categories (explicit lists with
 *     ordinals, implicit lists without them, step sequences, and negative
 *     cases that should NOT become lists), plus the repair step's overall
 *     detector-firing rate, applied/rejected/timeout counts, and added
 *     latency p50/p90 across the whole run.
 *
 * Usage (from server/, macOS with `say`/`afconvert` only):
 *   npx tsx --env-file=../.env.local scripts/format-eval.ts
 *   npx tsx --env-file=../.env.local scripts/format-eval.ts --case zh-explicit-1
 *   npx tsx --env-file=../.env.local scripts/format-eval.ts --keep-audio   # don't delete the generated WAVs
 *
 * Requires AI_GATEWAY_API_KEY. Synthesizes audio into a scratch temp dir by
 * default (cleaned up after the run) — pass --keep-audio to inspect it.
 */

import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

import { transcribeBatch } from "../lib/gateway";
import { repairListFormatting, type FormatRepairOutcome } from "../lib/list-repair";
import { normalizeListMarkers } from "../lib/text-format";

const execFileAsync = promisify(execFile);

type Category = "explicit-list" | "implicit-list" | "steps" | "negative";

interface FormatCase {
  id: string;
  language: "zh" | "en" | "mixed";
  voice: "Tingting" | "Samantha";
  category: Category;
  text: string;
  /** Human expectation, for the summary table only (not enforced automatically — SMART's formatting is non-deterministic). */
  expectListLike: boolean;
  /**
   * A known, tracked SMART limitation — a mismatch here is reported as
   * "KNOWN-GAP" instead of "DIFF" (no fix attempted; see the case's own
   * note for what was observed and why it's tracked rather than fixed).
   */
  knownGap?: string;
}

const CASES: FormatCase[] = [
  {
    id: "zh-explicit-1",
    language: "zh",
    voice: "Tingting",
    category: "explicit-list",
    text: "我们讲一下以下几个要点，第一，新版本周二上线。第二，客服要提前培训。第三，监控要加延迟指标。",
    expectListLike: true,
  },
  {
    id: "zh-explicit-2",
    language: "zh",
    voice: "Tingting",
    category: "explicit-list",
    text: "跟大家说几件事，首先，会议改到下午三点。其次，报告要提前交。最后，记得带电脑。",
    expectListLike: true,
  },
  {
    id: "en-explicit-1",
    language: "en",
    voice: "Samantha",
    category: "explicit-list",
    text: "Let me go over a few things. First, we need to update the docs. Second, we need to fix the login bug. Finally, we should deploy to staging.",
    expectListLike: true,
  },
  {
    id: "mixed-explicit-1",
    language: "mixed",
    voice: "Tingting",
    category: "explicit-list",
    text: "跟你说几个 points，first，这个 feature 要上线了。second，QA 还没测完。third，deadline 可能要往后推。",
    expectListLike: true,
  },
  {
    id: "zh-implicit-1",
    language: "zh",
    voice: "Tingting",
    category: "implicit-list",
    text: "我们需要做几件事，更新文档，修复登录的问题，然后部署到预发环境。",
    expectListLike: true,
  },
  {
    id: "en-implicit-1",
    language: "en",
    voice: "Samantha",
    category: "implicit-list",
    text: "There are a few things to do. Update the pricing page. Notify existing customers. Monitor the support tickets.",
    expectListLike: true,
  },
  {
    id: "mixed-implicit-1",
    language: "mixed",
    voice: "Tingting",
    category: "implicit-list",
    text: "有几个 action items，更新 readme，加 unit tests，然后 deploy 到 staging。",
    expectListLike: true,
    // Originally a tracked known gap (2026-09-26): SMART returned this as a
    // single run-on sentence with NO list formatting at all — unlike the
    // pure-zh and pure-en implicit-list cases (both correctly formatted).
    // FIXED (same day, follow-up task) by the P1.2.1 list-repair step
    // (lib/list-repair.ts, docs/PROMPTS.md §1b): this eval now runs that
    // same pipeline, and the repair reliably catches and reformats this
    // case (verified live, "applied", ~1.5s added latency). The `knownGap`
    // annotation is kept as a regression guard — if repair ever breaks,
    // this case flips back to reporting "KNOWN-GAP [still present]"
    // instead of silently passing.
    knownGap: "SMART sometimes fails to format mixed zh/en implicit (no-ordinal) spoken lists into Markdown — returns a single run-on sentence instead (now caught by the P1.2.1 list-repair step).",
  },
  {
    id: "zh-steps-1",
    language: "zh",
    voice: "Tingting",
    category: "steps",
    text: "操作步骤是这样的，第一步，打开设置。第二步，点击账户。第三步，选择注销。",
    expectListLike: true,
  },
  {
    id: "en-steps-1",
    language: "en",
    voice: "Samantha",
    category: "steps",
    text: "Here are the steps. Step one, open the settings. Step two, click on account. Step three, select sign out.",
    expectListLike: true,
  },
  {
    id: "zh-negative-single",
    language: "zh",
    voice: "Tingting",
    category: "negative",
    text: "今天天气不错，我们出去走走吧。",
    expectListLike: false,
  },
  {
    id: "zh-negative-runon",
    language: "zh",
    voice: "Tingting",
    category: "negative",
    text: "谢谢你的帮助，这次真的帮了大忙，然后还有下次也麻烦你了。",
    expectListLike: false,
  },
  {
    id: "en-negative-runon",
    language: "en",
    voice: "Samantha",
    category: "negative",
    text: "So I went to the store, and then I grabbed some coffee, and then I headed to the office.",
    expectListLike: false,
  },
  // --- P1.2.1 follow-up (list-repair): 3 more mixed zh/en implicit-list
  // clips (the category with the tracked gap) and 2 mixed negatives, to
  // confirm the repair step fixes the gap without over-triggering.
  {
    id: "mixed-implicit-2",
    language: "mixed",
    voice: "Tingting",
    category: "implicit-list",
    text: "有几个 things to do，更新 pricing page，通知 existing customers，然后 monitor 一下 support tickets。",
    expectListLike: true,
  },
  {
    id: "mixed-implicit-3",
    language: "mixed",
    voice: "Tingting",
    category: "implicit-list",
    text: "跟大家说几个 points，会议改到下午三点，报告要提前交，还有记得带 laptop。",
    expectListLike: true,
  },
  {
    id: "mixed-implicit-4",
    language: "mixed",
    voice: "Tingting",
    category: "implicit-list",
    text: "有几件 action items，fix 一下 login bug，写 unit tests，然后 update 一下 README。",
    expectListLike: true,
  },
  {
    id: "mixed-negative-1",
    language: "mixed",
    voice: "Tingting",
    category: "negative",
    text: "我今天开了个 meeting，然后跟 team 讨论了一下 roadmap，还有喝了杯咖啡。",
    expectListLike: false,
  },
  {
    id: "mixed-negative-2",
    language: "mixed",
    voice: "Tingting",
    category: "negative",
    text: "这个 feature 已经 ship 了，用户反馈还不错。",
    expectListLike: false,
  },
];

// --- audio synthesis (macOS `say` + `afconvert`) ----------------------------

async function synthesize(text: string, voice: string, outWavPath: string): Promise<void> {
  const aiffPath = outWavPath.replace(/\.wav$/, ".aiff");
  await execFileAsync("say", ["-v", voice, "-o", aiffPath, text]);
  await execFileAsync("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiffPath, outWavPath]);
}

// --- list-structure analysis -------------------------------------------

interface ListAnalysis {
  listDetected: boolean;
  style: "bullet" | "numbered" | "mixed" | "none";
  lineCount: number;
  leadInOnOwnLine: boolean | null; // null when there's no list to check a lead-in for
}

// Both "- " and "* " count as Markdown bullets (SMART has been observed to
// emit either); "1. " / "1、" as numbered.
const BULLET_LINE_RE = /^\s*[-*]\s+\S/;
const NUMBERED_LINE_RE = /^\s*\d+[.、]\s*\S/;

function analyzeListStructure(text: string): ListAnalysis {
  const rawLines = text.split("\n").map((l) => l.trim());
  const bulletLines = rawLines.filter((l) => BULLET_LINE_RE.test(l));
  const numberedLines = rawLines.filter((l) => NUMBERED_LINE_RE.test(l));
  const listDetected = bulletLines.length + numberedLines.length >= 2; // at least 2 list-like lines to call it a real list

  let style: ListAnalysis["style"] = "none";
  if (listDetected) {
    style = bulletLines.length > 0 && numberedLines.length > 0 ? "mixed" : bulletLines.length > 0 ? "bullet" : "numbered";
  }

  let leadInOnOwnLine: boolean | null = null;
  if (listDetected) {
    const firstListLineIdx = rawLines.findIndex((l) => BULLET_LINE_RE.test(l) || NUMBERED_LINE_RE.test(l));
    const linesBefore = rawLines.slice(0, firstListLineIdx).filter((l) => l.length > 0);
    leadInOnOwnLine = linesBefore.length > 0;
  }

  return { listDetected, style, lineCount: bulletLines.length + numberedLines.length, leadInOnOwnLine };
}

// --- main ----------------------------------------------------------------

async function main(): Promise<void> {
  if (!process.env.AI_GATEWAY_API_KEY) {
    console.error("AI_GATEWAY_API_KEY is not set. Run with --env-file=../.env.local (see the shebang) or export it.");
    process.exit(1);
  }
  try {
    await execFileAsync("say", ["-v", "?"]);
    await execFileAsync("afconvert", ["-h"]).catch(() => undefined); // -h exits non-zero but proves the binary runs
  } catch {
    console.error("This script requires macOS `say` and `afconvert` (not found or not runnable).");
    process.exit(1);
  }

  const argv = process.argv.slice(2);
  const caseIdArg = argv.includes("--case") ? argv[argv.indexOf("--case") + 1] : undefined;
  const keepAudio = argv.includes("--keep-audio");

  const cases = caseIdArg ? CASES.filter((c) => c.id === caseIdArg) : CASES;
  if (caseIdArg && cases.length === 0) {
    console.error(`No case with id "${caseIdArg}"`);
    process.exit(1);
  }

  const tmpDir = mkdtempSync(join(tmpdir(), "prosio-format-eval-"));
  console.log(`Synthesizing ${cases.length} clip(s) into ${tmpDir} ...`);

  interface Result {
    kase: FormatCase;
    rawTranscript: string; // straight from SMART, before marker normalization/repair
    transcript: string; // final, post-normalization, post-repair text — what the client would actually see
    analysis: ListAnalysis;
    formatRepair: FormatRepairOutcome;
    repairLatencyMs: number;
    error?: string;
  }
  const results: Result[] = [];

  for (const kase of cases) {
    const wavPath = join(tmpDir, `${kase.id}.wav`);
    try {
      await synthesize(kase.text, kase.voice, wavPath);
      const audio = readFileSync(wavPath);
      const { text: rawTranscript } = await transcribeBatch({ audio, mode: "smart", vocabulary: [], languageHints: [] });
      // Same pipeline POST /api/transcribe's cloud path runs: normalize
      // stray bullet glyphs, then the P1.2.1 list-repair step.
      const markerNormalized = normalizeListMarkers(rawTranscript);
      const repair = await repairListFormatting(markerNormalized);
      const analysis = analyzeListStructure(repair.text);
      results.push({
        kase,
        rawTranscript,
        transcript: repair.text,
        analysis,
        formatRepair: repair.formatRepair,
        repairLatencyMs: repair.latencyMs,
      });
      const matches = analysis.listDetected === kase.expectListLike;
      const tag = matches ? "OK       " : kase.knownGap ? "KNOWN-GAP" : "DIFF     ";
      console.log(
        `${tag} ${kase.id.padEnd(20)} listDetected=${String(analysis.listDetected).padEnd(5)} style=${analysis.style.padEnd(
          8
        )} leadIn=${String(analysis.leadInOnOwnLine).padEnd(5)} repair=${String(repair.formatRepair).padEnd(
          10
        )} (+${repair.latencyMs}ms) expected=${kase.expectListLike}`
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      results.push({
        kase,
        rawTranscript: "",
        transcript: "",
        analysis: { listDetected: false, style: "none", lineCount: 0, leadInOnOwnLine: null },
        formatRepair: null,
        repairLatencyMs: 0,
        error: message,
      });
      console.log(`ERROR ${kase.id.padEnd(20)} ${message}`);
    }
  }

  if (!keepAudio) {
    rmSync(tmpDir, { recursive: true, force: true });
  } else {
    console.log(`\nAudio kept at ${tmpDir}`);
  }

  console.log("\n--- Transcripts ---");
  for (const r of results) {
    console.log(`\n[${r.kase.id}] (${r.kase.category}, ${r.kase.language})`);
    console.log(`  spoken:        "${r.kase.text}"`);
    console.log(`  raw (SMART):   ${JSON.stringify(r.rawTranscript)}`);
    if (r.formatRepair !== null) {
      console.log(`  final (repaired, ${r.formatRepair}): ${JSON.stringify(r.transcript)}`);
    } else {
      console.log(`  final:         ${JSON.stringify(r.transcript)}`);
    }
  }

  console.log("\n--- Summary by category ---");
  const categories: Category[] = ["explicit-list", "implicit-list", "steps", "negative"];
  for (const category of categories) {
    const inCategory = results.filter((r) => r.kase.category === category && !r.error);
    if (inCategory.length === 0) continue;
    const listCount = inCategory.filter((r) => r.analysis.listDetected).length;
    const bulletCount = inCategory.filter((r) => r.analysis.style === "bullet").length;
    const numberedCount = inCategory.filter((r) => r.analysis.style === "numbered").length;
    const leadInCount = inCategory.filter((r) => r.analysis.leadInOnOwnLine === true).length;
    console.log(
      `${category.padEnd(15)} n=${inCategory.length}  list-detected=${listCount}/${inCategory.length}  bullet=${bulletCount} numbered=${numberedCount}  lead-in-on-own-line=${leadInCount}/${listCount || 0}`
    );
  }

  const errors = results.filter((r) => r.error);
  if (errors.length > 0) {
    console.log(`\n${errors.length} case(s) errored:`);
    for (const r of errors) console.log(`  ${r.kase.id}: ${r.error}`);
  }

  // --- P1.2.1 list-repair statistics ---
  console.log("\n--- List repair (P1.2.1, docs/PROMPTS.md §1b) ---");
  const nonError = results.filter((r) => !r.error);
  const fired = nonError.filter((r) => r.formatRepair !== null);
  const applied = fired.filter((r) => r.formatRepair === "applied");
  const rejected = fired.filter((r) => r.formatRepair === "rejected");
  const timedOut = fired.filter((r) => r.formatRepair === "timeout");
  console.log(`detector fired: ${fired.length}/${nonError.length} (${((fired.length / nonError.length) * 100).toFixed(0)}%)`);
  console.log(`  applied:  ${applied.length}`);
  console.log(`  rejected: ${rejected.length}`);
  console.log(`  timeout:  ${timedOut.length}`);
  if (fired.length > 0) {
    const firedLatencies = fired.map((r) => r.repairLatencyMs).sort((a, b) => a - b);
    const p = (pct: number) => firedLatencies[Math.min(firedLatencies.length - 1, Math.max(0, Math.ceil((pct / 100) * firedLatencies.length) - 1))]!;
    console.log(`  added latency (fired cases only): p50=${p(50)}ms p90=${p(90)}ms`);
  }
  const allLatencies = nonError.map((r) => r.repairLatencyMs).sort((a, b) => a - b);
  if (allLatencies.length > 0) {
    const p = (pct: number) => allLatencies[Math.min(allLatencies.length - 1, Math.max(0, Math.ceil((pct / 100) * allLatencies.length) - 1))]!;
    console.log(`  added latency (all cases, incl. 0ms no-op when detector doesn't fire): p50=${p(50)}ms p90=${p(90)}ms`);
  }
  if (applied.length > 0) {
    console.log("  applied cases:");
    for (const r of applied) console.log(`    ${r.kase.id}: "${r.rawTranscript}" -> "${r.transcript}"`);
  }
  if (rejected.length > 0) {
    console.log("  rejected cases (safety check failed, kept original):");
    for (const r of rejected) console.log(`    ${r.kase.id}: raw="${r.rawTranscript}"`);
  }

  const knownGaps = results.filter((r) => r.kase.knownGap);
  if (knownGaps.length > 0) {
    console.log("\nTracked known gaps (no fix attempted here):");
    for (const r of knownGaps) {
      const stillGapping = r.analysis.listDetected !== r.kase.expectListLike;
      console.log(`  ${r.kase.id} [${stillGapping ? "still present" : "not reproduced this run"}]: ${r.kase.knownGap}`);
    }
  }

  console.log(
    "\nConsistency note: SMART's list formatting is a model behavior, not a deterministic rule — expect some variance " +
      "run to run. This eval is a snapshot for calibration, not a hard pass/fail gate."
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
