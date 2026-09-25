#!/usr/bin/env -S npx tsx
/**
 * SMART-mode evaluation harness for the Prosio P0 transcription path.
 *
 * Default transport is **batch**: sends each recorded case's whole audio
 * file (eval/audio/<id>.wav, 16kHz mono PCM16 — the only rate Gemini
 * accepts) through the same `transcribeBatch()` helper (lib/gateway.ts)
 * that backs `POST /api/transcribe`, i.e. `experimental_transcribe` +
 * `gateway.transcriptionModel("google/gemini-3.5-transcribe")`. This is the
 * P0 architecture as of 2026-09-26: live-testing found Gateway's streaming
 * transcription (`google/gemini-3.5-transcribe-live`) unreliable (dropped
 * segments, ~3.5s to final), while batch SMART is reliable and ~2-4s. The
 * client shows an on-device live preview meanwhile and calls this batch
 * endpoint for the final, SMART-cleaned text.
 *
 * The old streaming path is kept for comparison behind --live (see
 * scripts/live-smoke.ts for a lower-level one-off streaming probe).
 *
 * Usage (from server/):
 *   npx tsx scripts/smart-eval.ts                  # run every case that has audio, batch transport
 *   npx tsx scripts/smart-eval.ts --case zh-01      # just one case
 *   npx tsx scripts/smart-eval.ts --mode verbatim   # compare against verbatim mode
 *   npx tsx scripts/smart-eval.ts --live            # use the streaming transport instead of batch
 *   npx tsx scripts/smart-eval.ts --dry-run         # validate cases.json + audio files, no API calls
 *   npx tsx scripts/smart-eval.ts --tts             # synthesize missing audio (smoke test only, see below)
 *
 * Requires AI_GATEWAY_API_KEY to actually call the Gateway. Without it,
 * every case fails with a clear "no Gateway key" error and the script still
 * exits 0 — see eval/README.md.
 *
 * === Provider options: confirmed vs inferred ===
 * SMART mode / vocabulary / language hints are passed as
 * `providerOptions.google` = `{ mode: "SMART" | "VERBATIM", customVocabulary:
 * string[], languageCodes: string[], wordTimestamp?, diarization? }`.
 * This shape is CONFIRMED by reading node_modules/@ai-sdk/google's
 * `googleTranscriptionModelOptions` zod schema (it maps onto Google's
 * `AudioTranscriptionConfig`), AND (for the batch transport, `google` key,
 * `mode`/`customVocabulary`) confirmed **live** against a real Gateway on
 * 2026-09-26. The `google` key for the *streaming* transport specifically
 * (--live) remains inferred rather than live-confirmed, since streaming
 * itself turned out unreliable enough that we didn't chase down its exact
 * provider-options wiring further — see GOOGLE_PROVIDER_OPTIONS_KEY below.
 */

import { randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import { gateway } from "@ai-sdk/gateway";
import { experimental_generateSpeech as generateSpeech, experimental_streamTranscribe as streamTranscribe } from "ai";

import { characterErrorRate } from "../lib/eval/cer";
import { runHeuristics, type HeuristicResult } from "../lib/eval/heuristics";
import { evalCasesSchema, type EvalCase, type EvalCaseResult, type EvalTransport, type TranscribeMode } from "../lib/eval/types";
import { transcribeBatch } from "../lib/gateway";
import { chunkPcm16, parseWav, WavParseError } from "../lib/wav";

const execFileAsync = promisify(execFile);

const __dirname = dirname(fileURLToPath(import.meta.url));
const EVAL_DIR = resolve(__dirname, "../../eval");
const AUDIO_DIR = join(EVAL_DIR, "audio");
const RESULTS_DIR = join(EVAL_DIR, "results");
const CASES_PATH = join(EVAL_DIR, "cases.json");

const LIVE_MODEL_ID = "google/gemini-3.5-transcribe-live"; // --live only; batch transport uses lib/gateway.ts's BATCH_TRANSCRIBE_MODEL.
const GOOGLE_PROVIDER_OPTIONS_KEY = "google"; // confirmed live for batch; see header comment for --live.
const CHUNK_MS = 50; // --live pacing only.
const PER_CASE_TIMEOUT_MS = 30_000;
const REQUIRED_SAMPLE_RATE = 16000; // Gemini (both batch and live) accepts only 16kHz mono PCM16.

// --- CLI args -----------------------------------------------------------

interface Args {
  caseId?: string;
  mode: TranscribeMode;
  transport: EvalTransport;
  dryRun: boolean;
  tts: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { mode: "smart", transport: "batch", dryRun: false, tts: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--case") {
      args.caseId = argv[++i];
    } else if (arg === "--mode") {
      const value = argv[++i];
      if (value !== "smart" && value !== "verbatim") {
        throw new Error(`--mode must be "smart" or "verbatim", got "${value}"`);
      }
      args.mode = value;
    } else if (arg === "--live") {
      args.transport = "live";
    } else if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--tts") {
      args.tts = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

// --- case loading ---------------------------------------------------------

function loadCases(): EvalCase[] {
  const raw = JSON.parse(readFileSync(CASES_PATH, "utf8"));
  const parsed = evalCasesSchema.safeParse(raw);
  if (!parsed.success) {
    console.error(`eval/cases.json failed validation:\n${parsed.error.message}`);
    process.exit(1);
  }
  return parsed.data;
}

function audioPathFor(id: string): string {
  return join(AUDIO_DIR, `${id}.wav`);
}

// --- dry run --------------------------------------------------------------

function dryRun(cases: EvalCase[]): void {
  console.log(`Validating ${cases.length} case(s) from ${CASES_PATH} (no API calls)...\n`);
  let ok = 0;
  let missingAudio = 0;
  let invalidAudio = 0;

  for (const kase of cases) {
    const path = audioPathFor(kase.id);
    if (!existsSync(path)) {
      console.log(`  ${kase.id.padEnd(14)} [no audio] ${path}`);
      missingAudio++;
      continue;
    }
    try {
      const wav = parseWav(readFileSync(path));
      const warn =
        wav.sampleRate !== REQUIRED_SAMPLE_RATE || wav.channels !== 1 || wav.bitsPerSample !== 16
          ? `  (expected ${REQUIRED_SAMPLE_RATE / 1000}kHz mono 16-bit PCM, got ${wav.sampleRate}Hz ${wav.channels}ch ${wav.bitsPerSample}-bit)`
          : "";
      console.log(`  ${kase.id.padEnd(14)} [ok] ${wav.sampleRate}Hz ${wav.channels}ch ${wav.bitsPerSample}-bit${warn}`);
      ok++;
    } catch (err) {
      const message = err instanceof WavParseError ? err.message : String(err);
      console.log(`  ${kase.id.padEnd(14)} [INVALID] ${message}`);
      invalidAudio++;
    }
  }

  console.log(`\n${ok} valid, ${missingAudio} missing audio, ${invalidAudio} invalid. cases.json schema: OK.`);
}

// --- TTS smoke-test audio synthesis ---------------------------------------

let ffmpegChecked: boolean | undefined;
async function hasFfmpeg(): Promise<boolean> {
  if (ffmpegChecked !== undefined) return ffmpegChecked;
  try {
    await execFileAsync("ffmpeg", ["-version"]);
    ffmpegChecked = true;
  } catch {
    ffmpegChecked = false;
  }
  return ffmpegChecked;
}

/**
 * Synthesizes audio for a case that has no recording, via the Gateway's TTS
 * surface, then converts it to 16kHz mono PCM16 WAV with ffmpeg (the only
 * rate Gemini accepts). NOT a substitute for a real human recording —
 * synthesized speech has none of the disfluencies/code-switching prosody
 * the eval cases are meant to exercise. Used only for wiring smoke tests.
 * Returns null on any failure (e.g. no AI_GATEWAY_API_KEY, no ffmpeg).
 */
async function synthesizeAudio(kase: EvalCase): Promise<string | null> {
  if (!(await hasFfmpeg())) {
    console.warn(`  [tts] ffmpeg not found; skipping synthesis for ${kase.id}`);
    return null;
  }
  try {
    const speechModel = gateway.speech("openai/tts-1");
    const result = await generateSpeech({ model: speechModel, text: kase.script, outputFormat: "mp3" });
    const tmpMp3 = join(tmpdir(), `prosio-eval-${kase.id}-${randomUUID()}.mp3`);
    writeFileSync(tmpMp3, result.audio.uint8Array);

    const outPath = join(AUDIO_DIR, `${kase.id}.generated.wav`);
    mkdirSync(AUDIO_DIR, { recursive: true });
    await execFileAsync("ffmpeg", [
      "-y",
      "-i",
      tmpMp3,
      "-ar",
      String(REQUIRED_SAMPLE_RATE),
      "-ac",
      "1",
      "-f",
      "wav",
      "-acodec",
      "pcm_s16le",
      outPath,
    ]);
    console.warn(`  [tts] SYNTHESIZED audio for ${kase.id} -> ${outPath} (smoke test only, not representative)`);
    return outPath;
  } catch (err) {
    console.warn(`  [tts] synthesis failed for ${kase.id}: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

// --- paced audio streaming --------------------------------------------------

function delay(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function createPacedAudioStream(chunks: Buffer[], chunkMs: number) {
  let resolveAudioEndedAt!: (t: number) => void;
  const audioEndedAt = new Promise<number>((resolve) => {
    resolveAudioEndedAt = resolve;
  });

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      for (const chunk of chunks) {
        controller.enqueue(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
        await delay(chunkMs);
      }
      controller.close();
      resolveAudioEndedAt(performance.now());
    },
  });

  return { stream, audioEndedAt };
}

function languageCodesFor(language: EvalCase["language"]): string[] {
  switch (language) {
    case "zh":
      return ["zh-CN"];
    case "en":
      return ["en-US"];
    case "mixed":
      return ["zh-CN", "en-US"];
  }
}

// --- running a single case --------------------------------------------------

/** Batch transport (P0 default): one request, whole file — mirrors POST /api/transcribe exactly via lib/gateway.ts's transcribeBatch. */
async function runCaseBatch(kase: EvalCase, audioPath: string, mode: TranscribeMode): Promise<EvalCaseResult> {
  const audioBuffer = readFileSync(audioPath);
  parseWav(audioBuffer); // validate sample-rate/format early, same as the route; return value unused (we send the whole file)
  const startedAt = performance.now();

  try {
    const result = await transcribeBatch({
      audio: audioBuffer, // whole WAV file — see BatchTranscribeParams's doc comment in lib/gateway.ts
      mode,
      vocabulary: kase.vocabulary,
      languageHints: languageCodesFor(kase.language),
    });
    const requestLatencyMs = performance.now() - startedAt;
    const { cer, editDistance } = characterErrorRate(result.text, kase.expected);

    return {
      id: kase.id,
      category: kase.category,
      language: kase.language,
      mode,
      transport: "batch",
      hasAudio: true,
      text: result.text,
      expected: kase.expected,
      cer,
      editDistance,
      timeToFirstPartialMs: null,
      timeToFinalAfterAudioEndMs: null,
      partialCount: 0,
      requestLatencyMs,
      heuristics: runHeuristics(kase, result.text),
    };
  } catch (err) {
    const requestLatencyMs = performance.now() - startedAt;
    const message = err instanceof Error ? err.message : String(err);
    return {
      id: kase.id,
      category: kase.category,
      language: kase.language,
      mode,
      transport: "batch",
      hasAudio: true,
      text: "",
      expected: kase.expected,
      cer: 1,
      editDistance: -1,
      timeToFirstPartialMs: null,
      timeToFinalAfterAudioEndMs: null,
      partialCount: 0,
      requestLatencyMs,
      heuristics: [],
      error: message,
    };
  }
}

/** Streaming transport (--live): kept for comparison. See header comment — live-tested unreliable, no longer the P0 default. */
async function runCaseLive(kase: EvalCase, audioPath: string, mode: TranscribeMode): Promise<EvalCaseResult> {
  const wav = parseWav(readFileSync(audioPath));
  const chunks = chunkPcm16(wav.data, wav.sampleRate, wav.channels, CHUNK_MS);
  const { stream, audioEndedAt } = createPacedAudioStream(chunks, CHUNK_MS);

  const model = gateway.experimental_transcription(LIVE_MODEL_ID);
  const abortController = new AbortController();
  const timeout = setTimeout(() => abortController.abort(), PER_CASE_TIMEOUT_MS);

  let finalText = "";
  let latestPartialText = "";
  let partialCount = 0;
  let firstPartialAtMs: number | null = null;
  const startedAt = performance.now();

  try {
    const result = streamTranscribe({
      model,
      audio: stream,
      inputAudioFormat: { type: "audio/pcm", rate: wav.sampleRate },
      abortSignal: abortController.signal,
      providerOptions: {
        [GOOGLE_PROVIDER_OPTIONS_KEY]: {
          mode: mode === "smart" ? "SMART" : "VERBATIM",
          customVocabulary: kase.vocabulary,
          languageCodes: languageCodesFor(kase.language),
        },
      },
    });

    // Drain fullStream to completion BEFORE touching any result promise:
    // per the SDK's own doc comment, accessing a result promise first
    // consumes the stream internally and makes fullStream unavailable.
    for await (const part of result.fullStream) {
      if (part.type === "transcript-partial") {
        partialCount++;
        latestPartialText = part.text;
        if (firstPartialAtMs === null) firstPartialAtMs = performance.now() - startedAt;
      } else if (part.type === "transcript-delta") {
        partialCount++;
        latestPartialText += part.delta;
        if (firstPartialAtMs === null) firstPartialAtMs = performance.now() - startedAt;
      } else if (part.type === "transcript-final") {
        finalText = part.text;
      } else if (part.type === "error") {
        throw part.error instanceof Error ? part.error : new Error(String(part.error));
      }
    }

    const audioEndAt = await audioEndedAt;
    const finalAtMs = performance.now();
    const text = finalText || latestPartialText;
    const { cer, editDistance } = characterErrorRate(text, kase.expected);

    return {
      id: kase.id,
      category: kase.category,
      language: kase.language,
      mode,
      transport: "live",
      hasAudio: true,
      text,
      expected: kase.expected,
      cer,
      editDistance,
      timeToFirstPartialMs: firstPartialAtMs,
      timeToFinalAfterAudioEndMs: finalText ? finalAtMs - audioEndAt : null,
      partialCount,
      requestLatencyMs: null,
      heuristics: runHeuristics(kase, text),
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      id: kase.id,
      category: kase.category,
      language: kase.language,
      mode,
      transport: "live",
      hasAudio: true,
      text: "",
      expected: kase.expected,
      cer: 1,
      editDistance: -1,
      timeToFirstPartialMs: firstPartialAtMs,
      timeToFinalAfterAudioEndMs: null,
      partialCount,
      requestLatencyMs: null,
      heuristics: [],
      error: message,
    };
  } finally {
    clearTimeout(timeout);
  }
}

function skippedResult(kase: EvalCase, mode: TranscribeMode, transport: EvalTransport, reason: string): EvalCaseResult {
  return {
    id: kase.id,
    category: kase.category,
    language: kase.language,
    mode,
    transport,
    hasAudio: false,
    text: "",
    expected: kase.expected,
    cer: NaN,
    editDistance: -1,
    timeToFirstPartialMs: null,
    timeToFinalAfterAudioEndMs: null,
    partialCount: 0,
    requestLatencyMs: null,
    heuristics: [],
    error: reason,
  };
}

// --- reporting --------------------------------------------------------------

function heuristicSummary(h: HeuristicResult[]): string {
  if (h.length === 0) return "-";
  return h.map((r) => `${r.passed ? "✓" : "✗"}${r.name}`).join(" ");
}

function buildMarkdown(results: EvalCaseResult[], mode: TranscribeMode, transport: EvalTransport): string {
  const lines: string[] = [];
  lines.push(`# SMART eval results (transport=${transport}, mode=${mode})`, "", `Generated ${new Date().toISOString()}`, "");
  lines.push("| id | category | lang | CER | latency (ms) | TTFP (ms) | TTFinal (ms) | partials | heuristics | note |");
  lines.push("|---|---|---|---|---|---|---|---|---|---|");
  for (const r of results) {
    const cer = r.hasAudio && !r.error ? r.cer.toFixed(3) : "-";
    const note = (r.error ?? "").replace(/\s*\n\s*/g, " ").slice(0, 140);
    lines.push(
      `| ${r.id} | ${r.category} | ${r.language} | ${cer} | ${r.requestLatencyMs?.toFixed(0) ?? "-"} | ${
        r.timeToFirstPartialMs?.toFixed(0) ?? "-"
      } | ${r.timeToFinalAfterAudioEndMs?.toFixed(0) ?? "-"} | ${r.partialCount} | ${heuristicSummary(r.heuristics)} | ${note} |`
    );
  }

  const scored = results.filter((r) => r.hasAudio && !r.error && !Number.isNaN(r.cer));
  if (scored.length > 0) {
    const meanCer = scored.reduce((s, r) => s + r.cer, 0) / scored.length;
    lines.push("", `**Mean CER (${scored.length} scored case(s)): ${meanCer.toFixed(3)}**`);

    const latencies = scored.map((r) => r.requestLatencyMs).filter((v): v is number => v !== null);
    if (latencies.length > 0) {
      const meanLatency = latencies.reduce((a, b) => a + b, 0) / latencies.length;
      lines.push(`**Mean request latency: ${meanLatency.toFixed(0)}ms**`);
    }

    const byCategory = new Map<string, number[]>();
    for (const r of scored) {
      const arr = byCategory.get(r.category) ?? [];
      arr.push(r.cer);
      byCategory.set(r.category, arr);
    }
    lines.push("", "| category | mean CER | n |", "|---|---|---|");
    for (const [cat, cers] of byCategory) {
      lines.push(`| ${cat} | ${(cers.reduce((a, b) => a + b, 0) / cers.length).toFixed(3)} | ${cers.length} |`);
    }
  }

  const skipped = results.length - scored.length;
  if (skipped > 0) {
    lines.push("", `${skipped} case(s) not scored (missing audio or an error — see the "note" column).`);
  }

  return lines.join("\n") + "\n";
}

// --- main --------------------------------------------------------------

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const allCases = loadCases();
  const cases = args.caseId ? allCases.filter((c) => c.id === args.caseId) : allCases;

  if (args.caseId && cases.length === 0) {
    console.error(`No case with id "${args.caseId}" in ${CASES_PATH}`);
    process.exit(1);
  }

  if (args.dryRun) {
    dryRun(cases);
    return;
  }

  if (!process.env.AI_GATEWAY_API_KEY) {
    console.warn(
      "AI_GATEWAY_API_KEY is not set — every case below will fail with an upstream error. " +
        "This script otherwise runs unchanged once a key is set.\n"
    );
  }

  console.log(`Transport: ${args.transport}${args.transport === "batch" ? " (P0 default)" : " (streaming, kept for comparison)"}\n`);

  const results: EvalCaseResult[] = [];
  for (const kase of cases) {
    let audioPath = audioPathFor(kase.id);
    if (!existsSync(audioPath)) {
      if (args.tts) {
        const synthesized = await synthesizeAudio(kase);
        if (!synthesized) {
          results.push(skippedResult(kase, args.mode, args.transport, "No audio file and TTS synthesis failed/unavailable"));
          continue;
        }
        audioPath = synthesized;
      } else {
        results.push(skippedResult(kase, args.mode, args.transport, "No audio file — see eval/README.md to record one"));
        continue;
      }
    }

    process.stdout.write(`Running ${kase.id}... `);
    const result = args.transport === "live" ? await runCaseLive(kase, audioPath, args.mode) : await runCaseBatch(kase, audioPath, args.mode);
    const timing = result.requestLatencyMs !== null ? ` (${result.requestLatencyMs.toFixed(0)}ms)` : "";
    console.log(result.error ? `error: ${result.error}` : `CER=${result.cer.toFixed(3)}${timing}`);
    results.push(result);
  }

  mkdirSync(RESULTS_DIR, { recursive: true });
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const jsonPath = join(RESULTS_DIR, `${timestamp}.json`);
  const mdPath = join(RESULTS_DIR, `${timestamp}.md`);

  writeFileSync(
    jsonPath,
    JSON.stringify({ mode: args.mode, transport: args.transport, generatedAt: new Date().toISOString(), results }, null, 2)
  );
  const markdown = buildMarkdown(results, args.mode, args.transport);
  writeFileSync(mdPath, markdown);

  console.log(`\nWrote ${jsonPath}\nWrote ${mdPath}\n`);
  console.log(markdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
