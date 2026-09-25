import { gateway } from "@ai-sdk/gateway";
import { experimental_transcribe as transcribe } from "ai";

/** Models the backend will mint transcription tokens for. First is the default. */
export const ALLOWED_TRANSCRIBE_MODELS = [
  "google/gemini-3.5-transcribe-live",
  "openai/gpt-realtime-whisper",
] as const;

export type AllowedTranscribeModel = (typeof ALLOWED_TRANSCRIBE_MODELS)[number];

export function isAllowedTranscribeModel(model: string): model is AllowedTranscribeModel {
  return (ALLOWED_TRANSCRIBE_MODELS as readonly string[]).includes(model);
}

export interface MintedGatewayToken {
  token: string;
  url: string;
  model: string;
  expiresAt: string; // ISO-8601
}

// Gateway's documented default token lifetime is 60s (max 300s) when
// expiresAfterSeconds is omitted. We ask for the max explicitly so a client
// has a comfortable window to open the transcription WebSocket, and so we
// have a reliable fallback for computing `expiresAt` if the SDK ever omits
// it (see below).
const TOKEN_TTL_SECONDS = 300;

/**
 * Mints a short-lived Gateway client secret for streaming transcription via
 * `gateway.experimental_transcription.getToken`. Throws on any upstream
 * failure (including a missing AI_GATEWAY_API_KEY) — callers should map
 * that to the API's 502 `upstream_error`.
 */
export async function mintTranscribeToken(model: AllowedTranscribeModel): Promise<MintedGatewayToken> {
  const result = await gateway.experimental_transcription.getToken({
    model,
    expiresAfterSeconds: TOKEN_TTL_SECONDS,
  });

  // GatewayTranscriptionFactoryGetTokenResult = { token, url, expiresAt?: epoch seconds }.
  // `expiresAt` is documented as optional; if the SDK/Gateway ever omits it,
  // fall back to now + the TTL we requested so callers still get a usable value.
  const expiresAt =
    typeof result.expiresAt === "number"
      ? new Date(result.expiresAt * 1000)
      : new Date(Date.now() + TOKEN_TTL_SECONDS * 1000);

  return {
    token: result.token,
    url: result.url,
    model,
    expiresAt: expiresAt.toISOString(),
  };
}

// --- Batch transcription (P0 final text; see docs/API.md § Batch transcription) ---
//
// Live-tested (2026-09-26, real AI_GATEWAY_API_KEY): streaming via
// gateway.experimental_transcription (above) was unreliable — dropped
// segments, ~3.5s to final. Batch `google/gemini-3.5-transcribe` + SMART via
// `transcribe()` is reliable and ~2-4s, and is now the P0 path for final
// text (the client shows an on-device live preview in the meantime, and
// streaming stays available behind --live in scripts/smart-eval.ts / in
// scripts/live-smoke.ts for future revisit). Gemini accepts only 16kHz mono
// PCM16 audio.

/** Fixed model for the batch endpoint — not client-selectable (docs/API.md has no `model` field on POST /api/transcribe). */
export const BATCH_TRANSCRIBE_MODEL = "google/gemini-3.5-transcribe";

export type TranscribeMode = "smart" | "verbatim";

export interface BatchTranscribeParams {
  /**
   * The WHOLE WAV file's bytes (RIFF header + data chunk), NOT just the raw
   * PCM payload — confirmed live: Gateway returns a 400 "Bad Request" from
   * Google if you strip the header and send bare PCM. Passing the full
   * container (as read straight off disk / decoded straight from the
   * request's base64) is what `transcribe()` expects.
   */
  audio: Uint8Array;
  mode: TranscribeMode;
  /** Personal-dictionary terms to bias recognition. Omitted from providerOptions when empty. */
  vocabulary: string[];
  /** BCP-47 language hints, e.g. ["zh-CN", "en-US"]. Omitted from providerOptions when empty. */
  languageHints: string[];
}

export interface BatchTranscribeResult {
  text: string;
  language: string | null;
}

/**
 * Batch-transcribes a complete recording via `transcribe()` +
 * `gateway.transcriptionModel(BATCH_TRANSCRIBE_MODEL)`. Throws on any
 * upstream failure (including a missing AI_GATEWAY_API_KEY) — callers
 * should map that to the API's 502 `upstream_error`.
 *
 * providerOptions.google shape confirmed live: `{ mode, customVocabulary?,
 * languageCodes? }` (see server/lib/eval/heuristics.ts's sibling comment in
 * scripts/smart-eval.ts for the streaming-path equivalent, which was
 * confirmed from @ai-sdk/google's source rather than a live call).
 */
export async function transcribeBatch(params: BatchTranscribeParams): Promise<BatchTranscribeResult> {
  const result = await transcribe({
    model: gateway.transcriptionModel(BATCH_TRANSCRIBE_MODEL),
    audio: params.audio,
    providerOptions: {
      google: {
        mode: params.mode === "smart" ? "SMART" : "VERBATIM",
        ...(params.vocabulary.length > 0 ? { customVocabulary: params.vocabulary } : {}),
        ...(params.languageHints.length > 0 ? { languageCodes: params.languageHints } : {}),
      },
    },
  });

  return { text: result.text, language: result.language ?? null };
}
