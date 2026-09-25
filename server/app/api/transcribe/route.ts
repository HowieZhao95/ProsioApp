import { after } from "next/server";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { ALLOWED_TRANSCRIBE_MODELS, mintTranscribeToken, transcribeBatch } from "@/lib/gateway";
import { getStore } from "@/lib/store";
import { RequestTimer } from "@/lib/timing";
import { parseWav, WavParseError } from "@/lib/wav";

// Node runtime (Buffer, base64 decode of up to ~3.9MB audio) + a longer
// maxDuration than the Next.js default, since a full-length (120s) SMART
// transcription can take a few seconds. Keep this module warm-friendly: the
// Gateway client (`@ai-sdk/gateway`'s `gateway` singleton, imported
// transitively via lib/gateway.ts) is created once per module instance, not
// per-request, so its underlying fetch/HTTP keep-alive connections are
// reused across requests in a warm process (verify with
// scripts/latency-bench.ts: later runs should be faster than the first).
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

/**
 * Runs `fn` after the response has been sent (via next/server's `after()`),
 * so a slow usage write never adds to client-observed latency. Falls back
 * to awaiting `fn` inline when called outside a Next.js request scope
 * (e.g. tests that invoke the route handler directly, or a future runtime
 * where `after()` isn't available) — `after()` throws synchronously in that
 * case, before `fn` ever runs, so this is a safe, side-effect-free probe.
 */
async function runAfterResponse(fn: () => Promise<void>): Promise<void> {
  try {
    after(fn);
  } catch {
    await fn();
  }
}

export const POST = withErrorHandling(async (req: Request) => {
  const timer = new RequestTimer();
  let outcome: "ok" | "error" = "ok";

  try {
    const user = await requireUser(req);
    timer.mark("auth");

    const json = await req.json().catch(() => null);
    const parsed = bodySchema.safeParse(json);
    if (!parsed.success) {
      throw new ApiError("bad_request", parsed.error.issues[0]?.message ?? "Invalid request body");
    }
    const { mode, vocabulary, languageHints, sessionID } = parsed.data;
    const audioBuffer = decodeBase64Audio(parsed.data.audio);
    timer.mark("parse");

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
    timer.mark("wav");

    const store = getStore();
    const entitlement = await getEntitlement(user.id);
    const { periodStart, periodEnd } = currentBillingPeriod();
    const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);
    if (audioSecondsUsed >= entitlement.audioSecondsLimit) {
      throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
    }
    timer.mark("quota");

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
    timer.mark("gateway");

    // Off the critical path: per docs/API.md usage must still be recorded
    // (idempotent on sessionID), but the client doesn't need to wait for
    // that write to see its transcript. See runAfterResponse's doc comment.
    void runAfterResponse(async () => {
      const usageTimer = new RequestTimer();
      await store.recordUsage(user.id, {
        sessionID,
        engineID: "cloud.gemini-3.5-transcribe",
        audioSeconds: durationSeconds,
        startedAt: new Date().toISOString(),
      });
      usageTimer.mark("usage");
      console.log("[transcribe] usage recorded post-response", { sessionID, ...usageTimer.toObject() });
    });

    return Response.json(
      { text: result.text, language: result.language, durationSeconds },
      { headers: { "Server-Timing": timer.toServerTimingHeader() } }
    );
  } catch (err) {
    outcome = "error";
    throw err;
  } finally {
    console.log("[transcribe]", { outcome, ...timer.toObject() });
  }
});

// In-flight warm-up promise, deduped: concurrent HEAD calls (e.g. a
// double key-down) share one warm-up instead of firing N Gateway requests.
// Reset to null once it settles so a LATER (non-concurrent) HEAD — e.g.
// after the connection has gone properly idle again — can warm again.
let warmPromise: Promise<void> | null = null;

function warmGatewayConnection(): Promise<void> {
  if (!warmPromise) {
    warmPromise = mintTranscribeToken(ALLOWED_TRANSCRIBE_MODELS[0])
      .then(() => undefined)
      .catch(() => undefined) // best-effort: a real request will surface any real problem with its own 502
      .finally(() => {
        warmPromise = null;
      });
  }
  return warmPromise;
}

/**
 * No auth: lets the client pre-warm the connection to us when dictation
 * starts, AND fires a cheap real Gateway request (getToken — no audio, no
 * model inference) to keep our long-keep-alive connection to the Gateway
 * (see lib/gateway.ts's `gatewayAgent`) actually warm. Fire-and-forget:
 * never blocks the 204.
 *
 * Earlier attempt at this (before the keep-alive agent existed) was A/B'd
 * with full cold-PROCESS restarts and showed no measurable benefit — wrong
 * test: a process restart's variance (module load, first-ever DNS lookup,
 * TCP slow start) swamps anything a HEAD warm-up could fix. Re-tested
 * 2026-09-26 the right way — idle gaps on an already-warm, long-running
 * process, which is what real dictation actually looks like (HEAD at
 * key-down, POST ~1-2s later once recording stops) — see
 * server/README.md's Latency section for the numbers this time.
 */
export async function HEAD(): Promise<Response> {
  void warmGatewayConnection();
  return new Response(null, { status: 204 });
}
