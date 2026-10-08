import { createGateway } from "@ai-sdk/gateway";
import { experimental_transcribe as transcribe } from "ai";
import { Agent as UndiciAgent, fetch as undiciFetch } from "undici";

// --- Long-keep-alive HTTP agent for the Gateway client ---------------------
//
// Live-measured (2026-09-26, real AI_GATEWAY_API_KEY, production `next
// start`): the first request after any idle gap of a few seconds pays a
// ~1.2-1.6s penalty vs. a back-to-back request. Node/undici's default
// `keepAliveTimeout` is ~4s — well under real dictation's think time between
// recordings — so the pooled connection to the Gateway is closing while
// idle and every "first request of a session" re-does a TCP+TLS handshake.
// Real dictation is almost always exactly that "first request after idle"
// case, so this is not a micro-optimization.
//
// Fix: give the Gateway client its own undici `Agent` with a much longer
// keep-alive, created once at module scope (so it — and whatever
// connections it's pooling — survives across requests in a warm process,
// not just within one). See server/README.md's Latency section for
// before/after numbers with idle gaps.
const GATEWAY_KEEP_ALIVE_MS = 60_000;
const gatewayAgent = new UndiciAgent({
  keepAliveTimeout: GATEWAY_KEEP_ALIVE_MS,
  keepAliveMaxTimeout: GATEWAY_KEEP_ALIVE_MS,
});

// Bridges undici's fetch (which accepts an undici-specific `dispatcher`
// option) to the plain `typeof globalThis.fetch` shape `@ai-sdk/gateway`
// expects. Undici's Request/Response/Headers are structurally compatible
// with the DOM lib's (same Fetch spec), just nominally different TS types —
// hence the casts.
const gatewayFetch: typeof globalThis.fetch = ((input: unknown, init?: unknown) =>
  undiciFetch(input as string, {
    ...(init as Record<string, unknown>),
    dispatcher: gatewayAgent,
  })) as unknown as typeof globalThis.fetch;

/**
 * Module-scope Gateway client (created once per warm process, like the
 * package's own default `gateway` singleton) — but with `gatewayFetch`
 * above so its connections use our long keep-alive instead of undici's
 * ~4s default. `transcribeBatch` below uses
 * this for HTTPS calls to the Gateway.
 */
export const gateway = createGateway({ fetch: gatewayFetch });

/** Warm the shared HTTPS connection without minting a streaming token. */
export async function warmGatewayConnection(): Promise<void> {
  await gatewayFetch("https://ai-gateway.vercel.sh", {
    method: "HEAD",
    signal: AbortSignal.timeout(5_000),
  });
}

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
  signal?: AbortSignal;
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
 * languageCodes? }` (see scripts/smart-eval.ts).
 */
export async function transcribeBatch(params: BatchTranscribeParams): Promise<BatchTranscribeResult> {
  const result = await transcribe({
    model: gateway.transcriptionModel(BATCH_TRANSCRIBE_MODEL),
    audio: params.audio,
    abortSignal: AbortSignal.any([...(params.signal ? [params.signal] : []), AbortSignal.timeout(25_000)]),
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
