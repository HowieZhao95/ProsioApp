import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { transcribeBatch } from "@/lib/gateway";
import { getStore } from "@/lib/store";
import { parseWav, WavParseError } from "@/lib/wav";

// Node runtime (Buffer, base64 decode of up to ~3.9MB audio) + a longer
// maxDuration than the Next.js default, since a full-length (120s) SMART
// transcription can take a few seconds. Keep this module warm-friendly: the
// Gateway client (`@ai-sdk/gateway`'s `gateway` singleton, imported
// transitively via lib/gateway.ts) is created once per module instance, not
// per-request.
export const runtime = "nodejs";
export const maxDuration = 30;
export const dynamic = "force-dynamic";

const MAX_AUDIO_SECONDS = 120;
const MAX_VOCABULARY_TERMS = 1000;
const MAX_TERM_LENGTH = 100;

const bodySchema = z.object({
  audio: z.string().min(1, "audio must be a non-empty base64 string"),
  mode: z.enum(["smart", "verbatim"]).default("smart"),
  vocabulary: z.array(z.string().max(MAX_TERM_LENGTH)).max(MAX_VOCABULARY_TERMS).default([]),
  languageHints: z.array(z.string()).default([]),
  sessionID: z.string().uuid(),
});

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function decodeBase64Audio(base64: string): Buffer {
  const trimmed = base64.replace(/\s+/g, "");
  if (!BASE64_RE.test(trimmed)) {
    throw new ApiError("bad_request", "audio must be valid base64");
  }
  const buf = Buffer.from(trimmed, "base64");
  if (buf.length === 0) {
    throw new ApiError("bad_request", "audio must be valid base64");
  }
  return buf;
}

export const POST = withErrorHandling(async (req: Request) => {
  const user = await requireUser(req);

  const json = await req.json().catch(() => null);
  const parsed = bodySchema.safeParse(json);
  if (!parsed.success) {
    throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid request body");
  }
  const { mode, vocabulary, languageHints, sessionID } = parsed.data;

  const audioBuffer = decodeBase64Audio(parsed.data.audio);

  let wav;
  try {
    wav = parseWav(audioBuffer);
  } catch (err) {
    const message = err instanceof WavParseError ? err.message : "audio must be a valid WAV file";
    throw new ApiError("bad_request", message);
  }
  if (wav.sampleRate !== 16000 || wav.channels !== 1 || wav.bitsPerSample !== 16) {
    throw new ApiError(
      "bad_request",
      `audio must be 16kHz mono 16-bit PCM, got ${wav.sampleRate}Hz ${wav.channels}ch ${wav.bitsPerSample}-bit`
    );
  }

  const durationSeconds = wav.data.length / (wav.sampleRate * wav.channels * 2);
  if (durationSeconds > MAX_AUDIO_SECONDS) {
    throw new ApiError("payload_too_large", `Audio is ${durationSeconds.toFixed(1)}s, max is ${MAX_AUDIO_SECONDS}s`);
  }

  const store = getStore();
  const entitlement = await getEntitlement(user.id);
  const { periodStart, periodEnd } = currentBillingPeriod();
  const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);
  if (audioSecondsUsed >= entitlement.audioSecondsLimit) {
    throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
  }

  let result;
  try {
    result = await transcribeBatch({
      // The whole WAV file (header + data), not just wav.data — see
      // BatchTranscribeParams's doc comment in lib/gateway.ts.
      audio: audioBuffer,
      mode,
      vocabulary,
      languageHints,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "Gateway request failed";
    throw new ApiError("upstream_error", `Transcription failed: ${message}`);
  }

  // Per docs/API.md: usage is recorded here (not by a separate client call
  // to POST /api/usage) for this path, idempotent on sessionID.
  await store.recordUsage(user.id, {
    sessionID,
    engineID: "cloud.gemini-3.5-transcribe",
    audioSeconds: durationSeconds,
    startedAt: new Date().toISOString(),
  });

  return Response.json({
    text: result.text,
    language: result.language,
    durationSeconds,
  });
});

/** No auth: lets the client pre-warm the TLS connection when dictation starts. */
export async function HEAD(): Promise<Response> {
  return new Response(null, { status: 204 });
}
