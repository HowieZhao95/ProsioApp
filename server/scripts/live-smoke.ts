/**
 * Live smoke test for Gateway streaming transcription (reference for the Swift client).
 * Streams a 16 kHz mono PCM16 (the only rate Gemini Live accepts) WAV at real-time pace and prints every stream part with timings.
 *
 *   npx tsx --env-file=../.env.local scripts/live-smoke.ts <file.wav> [smart|verbatim] [vocab,comma,separated]
 */
import { readFile } from "node:fs/promises";
import { experimental_streamTranscribe as streamTranscribe } from "ai";
import { gateway } from "@ai-sdk/gateway";

const [file, modeArg = "smart", vocabArg = ""] = process.argv.slice(2);
if (!file) throw new Error("usage: live-smoke.ts <file.wav> [smart|verbatim] [vocab]");

const wav = await readFile(file);
const dataOffset = wav.indexOf("data") + 8; // skip RIFF header up to the data chunk payload
// PAD_MS: append trailing silence before closing the stream (tests end-of-speech finalisation).
const RATE = Number(process.env.RATE ?? 16000);
const MODEL = process.env.MODEL ?? "google/gemini-3.5-transcribe-live";
const BPS = RATE * 2;
const padBytes = Math.round((Number(process.env.PAD_MS ?? 0) / 1000) * BPS) & ~1;
// LEAD_MS: prepend leading silence (tests whether audio sent before the upstream session is ready is dropped).
const leadBytes = Math.round((Number(process.env.LEAD_MS ?? 0) / 1000) * BPS) & ~1;
const pcm = Buffer.concat([Buffer.alloc(leadBytes), wav.subarray(dataOffset), Buffer.alloc(padBytes)]);
const CHUNK = BPS / 20; // 50 ms
const t0 = performance.now();
const ms = () => Math.round(performance.now() - t0);
let audioEndAt = 0;

const audio = new ReadableStream<Uint8Array>({
  async start(controller) {
    for (let i = 0; i < pcm.length; i += CHUNK) {
      controller.enqueue(new Uint8Array(pcm.subarray(i, i + CHUNK)));
      await new Promise((r) => setTimeout(r, 50));
    }
    audioEndAt = ms();
    controller.close();
  },
});

const result = streamTranscribe({
  model: gateway.transcriptionModel(MODEL),
  audio,
  inputAudioFormat: { type: "audio/pcm", rate: RATE },
  providerOptions: MODEL.startsWith("google/") ? {
    google: {
      mode: modeArg === "verbatim" ? "VERBATIM" : "SMART",
      ...(vocabArg ? { customVocabulary: vocabArg.split(",") } : {}),
    },
  } : undefined,
});

let firstPartialAt = 0;
for await (const part of result.fullStream) {
  const p = part as { type: string; [k: string]: unknown };
  if (p.type.startsWith("transcript") && !firstPartialAt) firstPartialAt = ms();
  if (p.type === "transcript-final" || p.type === "finish") console.log("   raw:", JSON.stringify(p).slice(0, 300));
  const detail = "delta" in p ? JSON.stringify(p.delta) : "text" in p ? JSON.stringify(p.text) : "";
  console.log(`${String(ms()).padStart(6)}ms  ${p.type.padEnd(20)} ${detail}`);
  if (p.type === "error") console.log(JSON.stringify(p, null, 1));
}
const doneAt = ms();
console.log(`\nmodel=${MODEL} mode=${modeArg} audio=${(pcm.length / BPS).toFixed(2)}s firstPartial=${firstPartialAt}ms audioEnd=${audioEndAt}ms finalAfterRelease=${doneAt - audioEndAt}ms`);
console.log(`FINAL: ${await result.text}`);
