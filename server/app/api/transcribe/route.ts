import { after } from "next/server";
import { z } from "zod";
import { requireUser } from "@/lib/auth";
import { currentBillingPeriod, getEntitlement } from "@/lib/entitlements";
import { ApiError, withErrorHandling } from "@/lib/errors";
import { ALLOWED_TRANSCRIBE_MODELS, mintTranscribeToken, transcribeBatch } from "@/lib/gateway";
import { classifyIntent, type IntentDecision } from "@/lib/intent";
import { OggOpusParseError, parseOggOpus } from "@/lib/ogg-opus";
import { appContextSchema } from "@/lib/schemas";
import { getStore } from "@/lib/store";
import { normalizeListMarkers } from "@/lib/text-format";
import { RequestTimer } from "@/lib/timing";
import { checkLocalTranscript, type LocalCheckDecision } from "@/lib/transcribe-routing";
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

// P1.2 (docs/P1.2-AUDIO-ROUTING.md §1/§3): Ogg/Opus uploads are ~16x
// smaller than WAV at identical transcribed text, so the cap can be much
// higher while staying well under Vercel's 4.5MB body limit; WAV keeps its
// original cap since it's still uncompressed PCM.
const MAX_AUDIO_SECONDS_WAV = 120;
const MAX_AUDIO_SECONDS_OGG_OPUS = 600;
const MAX_VOCABULARY_TERMS = 1000;
const MAX_TERM_LENGTH = 100;
const MAX_LOCAL_TRANSCRIPT_CHARS = 4000; // matches POST /api/intent's transcript cap

const AUDIO_FORMATS = ["wav", "ogg-opus"] as const;
type AudioFormat = (typeof AUDIO_FORMATS)[number];

function isAudioFormat(value: string): value is AudioFormat {
  return (AUDIO_FORMATS as readonly string[]).includes(value);
}

const bodySchema = z.object({
  audio: z.string().min(1, "audio must be a non-empty base64 string"),
  // Not a z.enum(): an unrecognized value must produce 415, not 400 —
  // validated (and cast) manually right after parsing, see isAudioFormat().
  audioFormat: z.string().default("wav"),
  mode: z.enum(["smart", "verbatim"]).default("smart"),
  vocabulary: z.array(z.string().max(MAX_TERM_LENGTH)).max(MAX_VOCABULARY_TERMS).default([]),
  languageHints: z.array(z.string()).default([]),
  sessionID: z.string().uuid(),
  // P1.2: the on-device transcript, for the combined route+intent check
  // (lib/transcribe-routing.ts). Optional/nullable for backward
  // compatibility with clients that don't send it yet — see the "no
  // localTranscript" branch below for exactly what that degrades to.
  localTranscript: z.string().max(MAX_LOCAL_TRANSCRIPT_CHARS).nullable().optional(),
  hasSelection: z.boolean().default(false),
  app: appContextSchema,
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

// Strips common zh/en punctuation and whitespace, then compares the first
// 6 remaining characters — docs/P1.2-AUDIO-ROUTING.md §3's informal "first
// ~6 non-punctuation chars" leading-text check, used to decide whether the
// final (cloud) text has diverged enough from the local one that the
// earlier intent classification should be redone on the final text instead
// of reused. Unicode-aware (Array.from, not raw slicing) so a single CJK
// character never gets split.
const LEADING_PUNCTUATION_RE = /[\s.,!?;:，。！？；：、"'“”‘’()（）\-—…]/gu;

function leadingSignature(text: string): string {
  return Array.from(text.replace(LEADING_PUNCTUATION_RE, "")).slice(0, 6).join("");
}

function leadingTextDiffers(a: string, b: string): boolean {
  return leadingSignature(a) !== leadingSignature(b);
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
    const { mode, vocabulary, languageHints, sessionID, localTranscript, hasSelection, app } = parsed.data;
    if (!isAudioFormat(parsed.data.audioFormat)) {
      throw new ApiError(
        "unsupported_media_type",
        `Unsupported audioFormat "${parsed.data.audioFormat}" (expected "wav" or "ogg-opus")`
      );
    }
    const audioFormat = parsed.data.audioFormat;
    const audioBuffer = decodeBase64Audio(parsed.data.audio);
    timer.mark("parse");

    // --- Audio validation + duration (format-specific) ---------------------
    let durationSeconds: number;
    if (audioFormat === "wav") {
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
      durationSeconds = wav.data.length / (wav.sampleRate * wav.channels * 2);
      if (durationSeconds > MAX_AUDIO_SECONDS_WAV) {
        throw new ApiError("payload_too_large", `Audio is ${durationSeconds.toFixed(1)}s, max is ${MAX_AUDIO_SECONDS_WAV}s`);
      }
    } else {
      let ogg;
      try {
        ogg = parseOggOpus(audioBuffer);
      } catch (err) {
        const message = err instanceof OggOpusParseError ? err.message : "audio must be a valid Ogg/Opus file";
        throw new ApiError("bad_request", message);
      }
      if (ogg.channelCount !== 1) {
        throw new ApiError("bad_request", `Ogg/Opus audio must be mono, got ${ogg.channelCount} channels`);
      }
      durationSeconds = ogg.durationSeconds;
      if (durationSeconds > MAX_AUDIO_SECONDS_OGG_OPUS) {
        throw new ApiError(
          "payload_too_large",
          `Audio is ${durationSeconds.toFixed(1)}s, max is ${MAX_AUDIO_SECONDS_OGG_OPUS}s for ogg-opus`
        );
      }
    }
    timer.mark("audio");

    const store = getStore();
    const entitlement = await getEntitlement(user.id);
    const { periodStart, periodEnd } = currentBillingPeriod();
    const audioSecondsUsed = await store.sumUsage(user.id, periodStart, periodEnd);
    if (audioSecondsUsed >= entitlement.audioSecondsLimit) {
      throw new ApiError("quota_exceeded", "Monthly audio quota exhausted");
    }
    timer.mark("quota");

    // Usage is metered by audio duration regardless of which path below is
    // taken (docs/P1.2-AUDIO-ROUTING.md §3) — the local fast path still
    // costs the user's quota minutes even though it costs no Gemini tokens.
    // Deferred past the response either way; see runAfterResponse's doc
    // comment.
    const recordUsage = () =>
      runAfterResponse(async () => {
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

    // --- P1.2 combined route+intent check on the local transcript ---------
    let local: LocalCheckDecision | null = null;
    if (localTranscript) {
      local = await checkLocalTranscript({
        transcript: localTranscript,
        vocabulary,
        languageHints,
        hasSelection,
        appName: app?.appName ?? null,
      });
      timer.mark("local-check");

      if (!local.needsCloud && (local.intent === "dictate" || local.intent === "edit")) {
        // Clean enough, and the user wants it typed/applied as-is: skip
        // Gemini entirely (source: "local"). No gateway timer mark — there
        // was no Gateway call.
        void recordUsage();
        return Response.json(
          {
            text: localTranscript,
            language: null,
            durationSeconds,
            source: "local",
            intent: {
              intent: local.intent,
              confidence: local.intentConfidence,
              source: local.intentSource,
              classifiedOn: "local",
            },
            route: { cleanProbability: local.cleanProbability, reason: local.reason },
          },
          { headers: { "Server-Timing": timer.toServerTimingHeader() } }
        );
      }
    }

    // --- Cloud path (today's behavior, extended with source/intent/route) --
    let result;
    try {
      result = await transcribeBatch({
        // The whole file's bytes (WAV header+data, or the whole Ogg
        // container), not just raw PCM — see BatchTranscribeParams's doc
        // comment in lib/gateway.ts. `transcribe()` auto-detects the media
        // type from magic bytes for both formats; nothing format-specific
        // is passed here.
        audio: audioBuffer,
        mode,
        vocabulary,
        languageHints,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "Gateway request failed";
      throw new ApiError("upstream_error", `Transcription failed: ${message}`);
    }
    // Normalize stray bullet-marker glyphs ("* "/"• "/"· "/"– ") to "- "
    // (lib/text-format.ts, auto-formatting follow-up) — done once here so
    // every downstream use (leading-text comparison, intent reclassify,
    // and the response body) sees the same normalized text.
    const finalText = normalizeListMarkers(result.text);
    timer.mark("gateway");

    // Reclassify intent on the final text when there was no usable local
    // classification to reuse: no localTranscript was sent at all, the
    // local check's intent came back null (Jev unavailable, or the answer
    // was structurally invalid), or the final text's leading ~6
    // non-punctuation characters differ enough from the local transcript's
    // that the earlier classification might no longer apply (per
    // docs/P1.2-AUDIO-ROUTING.md §3). Otherwise the local classification is
    // reused as-is — it already answered the same question, just against
    // text that turned out close enough to the final.
    let intentResult: { intent: IntentDecision["intent"]; confidence: IntentDecision["confidence"]; source: IntentDecision["source"]; classifiedOn: "local" | "final" };
    if (local !== null && local.intent !== null && !leadingTextDiffers(localTranscript ?? "", finalText)) {
      intentResult = { intent: local.intent, confidence: local.intentConfidence, source: local.intentSource, classifiedOn: "local" };
    } else {
      const reclassified = await classifyIntent({ transcript: finalText, hasSelection, appName: app?.appName ?? null });
      timer.mark("reclassify");
      intentResult = { intent: reclassified.intent, confidence: reclassified.confidence, source: reclassified.source, classifiedOn: "final" };
    }

    void recordUsage();

    return Response.json(
      {
        text: finalText,
        language: result.language,
        durationSeconds,
        source: "cloud",
        intent: intentResult,
        route: local ? { cleanProbability: local.cleanProbability, reason: local.reason } : { cleanProbability: null, reason: "no-local-transcript" },
      },
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
