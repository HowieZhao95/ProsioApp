# Vercel AI Gateway — streaming transcription wire protocol

Reverse-engineered for `GatewayTranscriptionEngine` (Swift, `URLSessionWebSocketTask`). No official Swift SDK
exists; this document is the source of truth for what our client must send/parse.

Sources (installed in a scratch npm project, versions pinned at research time):
- `ai@7.0.114` — `experimental_streamTranscribe`
- `@ai-sdk/gateway@4.0.92` — `src/gateway-transcription-model.ts`, `src/gateway-realtime-auth.ts`, `src/gateway-provider.ts`
- `@ai-sdk/provider-utils@5.0.47` — `src/transcription-stream-envelope.ts` (the envelope codec, shared by client
  and the Gateway server), `src/connect-to-websocket.ts`
- `@ai-sdk/google@<latest>` — `src/transcription/google-transcription-model.ts`,
  `src/transcription/google-transcription-model-options.ts` (Google-specific `providerOptions`, and the
  *direct-to-Google* live model, used as a secondary signal only — see the risk note at the end)
- Docs: https://vercel.com/docs/ai-gateway/modalities/speech-to-text (fetched 2026-09-26),
  https://ai-sdk.dev/docs/ai-sdk-core/transcription (fetched 2026-09-26)

All facts below are marked **[confirmed: <file>]** (read directly in SDK source or official docs) or
**[inferred]** (plausible but not directly observed).

## 1. Token minting (server-side, not our concern directly)

Our `docs/API.md` `/api/transcribe/token` wraps this. **[confirmed: gateway-provider.ts]**

```ts
const { token, url, expiresAt } = await gateway.experimental_transcription.getToken({
  model: 'google/gemini-3.5-transcribe-live',
  expiresAfterSeconds: 60, // default 60, max 300
});
// token: a "vcst_..." single-use client secret
// url: the WS URL for this model (see §2)
// expiresAt: epoch seconds
```

`GatewayToken.url` in our Swift contract is exactly this `url`.

## 2. WebSocket URL

**[confirmed: gateway-transcription-model.ts `toGatewayTranscriptionUrl`]**

```
wss://ai-gateway.vercel.sh/v4/ai/transcription-model?ai-model-id=google%2Fgemini-3.5-transcribe-live
```

Built by taking the Gateway `baseURL` (`https://ai-gateway.vercel.sh/v4/ai` by default), replacing the scheme
`http→ws`, appending `/transcription-model`, and putting the model id in the `ai-model-id` query parameter
(URL-encoded, since ids contain `/`). This is exactly the `url` the token endpoint returns, so our client should
just use `GatewayToken.url` — it does **not** need to rebuild it.

## 3. Auth: WebSocket subprotocols, not headers

**[confirmed: gateway-realtime-auth.ts]** Browsers' `WebSocket` cannot set arbitrary headers, so the token rides
`Sec-WebSocket-Protocol` (the same trick as `openai-insecure-api-key.<token>`). `URLSessionWebSocketTask` also
cannot set an `Authorization` header for the upgrade in a portable way, so we use the same subprotocol scheme:

```
Sec-WebSocket-Protocol: ai-gateway-transcription.v1, ai-gateway-auth.<token>
```

- First protocol offered is always the literal marker `ai-gateway-transcription.v1`.
- Second is `ai-gateway-auth.` + the raw token string (must itself be a valid HTTP token — Gateway-issued
  `vcst_...` secrets are).
- An optional third, `ai-gateway-team.<base64url(teamIdOrSlug)>` (no padding), is irrelevant for us — team
  scoping is a server concern, already encoded into the minted token.

In Swift: `URLSessionWebSocketTask` is created via
`session.webSocketTask(with: URLRequest)` where the request has
`request.addValue("ai-gateway-transcription.v1, ai-gateway-auth.\(token)", forHTTPHeaderField: "Sec-WebSocket-Protocol")`.
(`URLSession` does allow setting this specific header on the upgrade request, unlike `Authorization`.)

## 4. Envelope rules (client ⇄ Gateway server)

**[confirmed: provider-utils `transcription-stream-envelope.ts`]** — this is the generic, provider-agnostic
envelope every Gateway transcription model speaks; the Gateway server adapts it to whatever the underlying
provider (Google, OpenAI, ...) actually needs.

1. Client sends exactly one `transcription-stream.start` **TEXT** frame first, immediately after the socket opens.
2. Audio rides **BINARY** frames: raw PCM16LE bytes, chunked to at most **64 KiB** per frame (server hard limit is
   256 KiB; the client should stay well under it and back off on send-buffer pressure — the JS client waits for
   the socket's buffered-amount to drain between frames).
3. Client signals end-of-audio with a `transcription-stream.audio-done` **TEXT** frame. A close without ever
   sending this is treated as an abort, not a normal end.
4. Every server→client TEXT frame is exactly one JSON-serialized stream part (flat object, no envelope wrapper).
5. Server closes with WS code **1000** right after sending the `finish` part. On failure the server sends one
   `error` part and then closes non-1000; a close that never sent `finish` is itself an error condition.
6. Unknown `type` values are ignored both directions (forward compatibility) — our JSON decoder must not throw on
   an unrecognized `type`.
7. Max frame size the server accepts: **256 KiB** (server-enforced; oversized frames are presumably rejected/close
   the socket — not observed directly).

### 4a. Start frame (client → server)

**[confirmed: transcription-stream-envelope.ts, gateway-transcription-model.ts]**

```json
{
  "type": "transcription-stream.start",
  "inputAudioFormat": { "type": "audio/pcm", "rate": 16000 },
  "providerOptions": {
    "google": {
      "mode": "SMART",
      "customVocabulary": ["Prosio", "Kubernetes"],
      "languageCodes": ["zh-CN", "en-US"]
    }
  }
}
```

- `inputAudioFormat.type` is a free-form string; `"audio/pcm"` is what every example (Gateway docs, OpenAI/Google
  examples) uses for raw 16-bit PCM. `rate` is the sample rate in Hz.
- `providerOptions` is passed through **verbatim** to the provider; only the `google` key matters for us. Its
  shape (Zod schema `googleTranscriptionModelOptions`, **[confirmed:
  google-transcription-model-options.ts]**):
  - `mode`: `"SMART" | "VERBATIM"` — SMART removes fillers, resolves self-corrections, formats punctuation/lists;
    VERBATIM is literal. This is the field our `TranscriptionMode` maps to (`.smart` → `"SMART"`, `.verbatim` →
    `"VERBATIM"`, or omit the key entirely for verbatim since it's the provider default).
  - `customVocabulary`: `[String]` — free-form bias phrases. Maps directly from `TranscriptionOptions.vocabulary`.
  - `languageCodes`: `[String]` (BCP-47) — hints, empty/omitted = auto-detect. Maps from
    `TranscriptionOptions.languageHints`.
  - `wordTimestamp`, `diarization`: booleans, not used by us (no corresponding contract field); omit.
  - Omit the `google` object entirely when there is nothing to say (defaults: VERBATIM, auto-detect, no
    vocabulary) rather than sending an empty object.
- `includeRawChunks` (bool, optional) — not needed; omit.

### 4b. Audio-done frame (client → server)

**[confirmed]**

```json
{ "type": "transcription-stream.audio-done" }
```

Send this once, right after the last audio BINARY frame, when our input `AsyncStream<AudioChunk>` finishes (i.e.
`AudioCapture.stop()` was called and its stream drained). Do not send further audio frames afterward.

### 4c. Server → client stream parts

**[confirmed: transcription-stream-envelope.ts `parseTranscriptionStreamPart`]** — the validated field set per
`type` (fields not listed are ignored by us):

| `type` | fields | our handling |
|---|---|---|
| `stream-start` | `warnings: [{type, ...}]` | ignore (log warnings if present) |
| `transcript-delta` | `delta: String`, `id?`, `providerMetadata?` | commit `delta` as the current segment's finished, SMART-cleaned text (see below), emit `.partial(committed)` |
| `transcript-partial` | `text: String` (raw in-progress text for the CURRENT segment, replacing the previous partial — not a delta!), `startSecond?`, `durationInSeconds?`, `channelIndex?` | replace the current segment's live text, emit `.partial(committed + currentPartial)` |
| `transcript-final` | `text: String`, `startSecond?`, `endSecond?`, `channelIndex?` | remembered only as a fallback source for the terminal `.final` text (see `finish` below); does **not** affect the running `.partial` |
| `finish` | `text: String` (**full final transcript**), `segments: [{text, startSecond, endSecond}]`, `language?`, `durationInSeconds?` | this is the terminal event: emit our contract's `.final(text)` exactly once, then finish our stream |
| `response-metadata` | `modelId?`, `headers?`, `timestamp?` (ISO 8601, revived to `Date`) | ignore |
| `raw` | `rawValue` | ignore (only present when `includeRawChunks: true`, which we never set) |
| `error` | `error: { message, type? }` (or arbitrary payload) | terminal — map to `ProsioError.transcriptionFailed(message)` and fail our stream; per envelope rule 5, stop sending audio and expect the socket to close non-1000 shortly after |

**Important divergence from the task brief's "transcript-delta / transcript-final" simplification, corrected
against a live run (2026-09-26) — `transcript-delta`'s semantics were initially assumed wrong.** The real envelope
has *five* transcript-related part types (`stream-start`, `transcript-delta`, `transcript-partial`,
`transcript-final`, `finish`), and **`finish` — not `transcript-final`** — carries the authoritative full-session
final text and is the terminal signal per envelope rule 5.

Confirmed live wire behavior for `google/gemini-3.5-transcribe-live`: the server emits `transcript-partial` (raw,
in-progress text for the CURRENT segment, replacing — not appending to — the previous partial within that
segment), then exactly one `transcript-delta` per segment (the SMART-cleaned, **committed** text for that whole
segment — **it supersedes the segment's partials; it is NOT an incremental append fragment**, unlike what the
envelope's generic field name suggests and unlike other providers may behave), then a new segment's partials start
fresh on top of what's committed. Treating `transcript-delta` as append-only (the original assumption here)
produces garbled/duplicated text (e.g. `"…Actually, no, let'sSo I think we should ship the Prosio beta on
Monday."`) because it double-counts the segment's already-received partial text.

Our (corrected) implementation strategy — see `GatewayTranscriptAccumulator`
(`Packages/ProsioKit/Sources/ProsioTranscription/Gateway/GatewayTranscriptAccumulation.swift`):

- Maintain `committed: String` (sum of every finished segment's `transcript-delta` text) and
  `currentPartial: String` (the live, still-revisable text of whichever segment hasn't produced its
  `transcript-delta` yet).
- On `transcript-partial`: `currentPartial = text` (replace, not append); emit `.partial(committed + currentPartial)`
  (joined with a space only when it looks genuinely needed — no space is inserted across CJK/punctuation
  boundaries, since the provider's own text already carries its spacing/punctuation).
- On `transcript-delta`: `committed = join(committed, delta)`; `currentPartial = ""`; emit
  `.partial(committed)`.
- On `transcript-final` (may appear near the end with a fuller text): remembered only as a fallback for `finish`'s
  text; does **not** update `committed`/`currentPartial` or emit a `.partial`.
- On `finish`: resolve the terminal text as `finish.text` if non-empty, else the last `transcript-final` text if
  non-empty, else `committed`; emit `.final(resolved)` exactly once, then finish the `AsyncThrowingStream`. If the
  resolved text is empty, throw `ProsioError.emptyTranscript` instead per our contract's error surface.
- On `error`: throw `ProsioError.transcriptionFailed(message)`.
- On socket close without a prior `finish`/`error`: throw `ProsioError.network("closed without finish")`.

**Live-preview note**: this Gateway streaming path is no longer the live-preview source in the app (that's now
`SpeechAnalyzerEngine`, on-device) — `GatewayTranscriptionEngine` remains available as an alternative streaming
engine and stays correct, but is not on the critical UI-latency path.

### 4d. Close semantics

**[confirmed: gateway-transcription-model.ts, connect-to-websocket.ts]**

- Server closes **1000** right after `finish` — this is success.
- Server sends `error` then closes non-1000 — this is failure (we already threw on the `error` part, so the
  close is a no-op).
- Any other close (e.g. idle timeout, network drop) before a `finish`/`error` was seen is an error:
  `ProsioError.network("...")`.
- Client-initiated cancellation: call `socket.close(1000)` (or any code) promptly; do **not** wait for a server
  response. `URLSessionWebSocketTask.cancel(with:reason:)` is the Swift equivalent.

## 5. Session limits

- **256 KiB max message size** — **[confirmed: transcription-stream-envelope.ts comment, "the AI Gateway rejects
  frames over 256 KiB"]**. We chunk audio at 64 KiB (**[confirmed]**, matches the JS client's
  `MAX_AUDIO_FRAME_BYTES`) — comfortably under the limit, and our actual chunks (~50 ms @ 16 kHz mono 16-bit = 800
  samples ≈ 1.6 KB) are far smaller still, so chunking logic is mostly a safety net, not something we expect to
  trigger in practice.
- **5-minute idle timeout** — **[inferred / not found in SDK source]**. This number comes from the task brief,
  not from anything in `@ai-sdk/gateway`, `@ai-sdk/provider-utils`, or the fetched docs pages. Treat it as
  unconfirmed; our client-side timeouts (8 s for `finish` after audio-done, per §6) make it moot in the P0 flow
  since we never hold an idle connection open that long.
- **Token TTL**: default 60 s, max 300 s — **[confirmed: docs + `GatewayTranscriptionFactoryGetTokenOptions`]**.
  Irrelevant to the WS engine itself (handled by `GatewayTokenProviding` / the backend), but relevant to
  `GatewayToken.expiresAt` — connect promptly after minting.

## 6. Our Swift client's timeout policy (not part of the wire protocol, but documented here since it's the
   natural companion)

- Connect (WS handshake open): 5 s.
- After sending `audio-done`, wait up to 8 s for `finish`; otherwise throw `ProsioError.network("final timeout")`.
- Cancellation of the consuming `Task` closes the socket immediately (best-effort `close(1000)`) and the
  `AsyncThrowingStream` finishes by throwing `CancellationError` / `ProsioError.cancelled`.

## 7. Audio format — 16 kHz only for Gemini Live, confirmed live

**[confirmed live, 2026-09-26 — reported by the architect from live testing against the real Gateway with a real
`AI_GATEWAY_API_KEY`]** Sending `inputAudioFormat.rate: 24000` for `google/gemini-3.5-transcribe-live` returns
**HTTP 400 "Unsupported inputAudioFormat"**. `google/gemini-3.5-transcribe-live` only accepts exactly **16 kHz,
16-bit PCM, mono** — this is not provider-adapted/resampled server-side the way the generic envelope's flexible
`rate` field might suggest.

This matches the SDK-source signal found earlier: `@ai-sdk/google`'s **direct-to-Google** live transcription
client (`GoogleTranscriptionModel.doStream`) hard-validates the same constraint:

```ts
function validateLiveInputAudioFormat(inputAudioFormat) {
  if (inputAudioFormat.type !== 'audio/pcm' || (inputAudioFormat.rate != null && inputAudioFormat.rate !== 16000)) {
    throw new InvalidArgumentError({
      argument: 'inputAudioFormat',
      message: 'The Gemini Live transcription API only supports 16kHz 16-bit PCM input audio.',
    });
  }
}
```

**[confirmed: google-transcription-model.ts:670]** — and the Gateway server evidently enforces the same rule for
this model rather than resampling on our behalf.

**Resolution**: the app's audio contract (`AudioFormat.pcm16Mono16k`, formerly `pcm16Mono24k`) was changed to
16 kHz everywhere — `AudioCapture` now captures at 16 kHz directly, so `GatewayTranscriptionEngine` sends
`chunk.pcm16` straight to the wire with **no resampling step** (the linear-interpolation resampler that used to
convert 24 kHz → 16 kHz here was deleted as dead code once the contract rate changed). `wireSampleRate` in
`GatewayTranscriptionEngine` is now defined as `AudioFormat.pcm16Mono16k.sampleRate` — i.e. it is definitionally
identical to the contract rate, not a separate constant that happens to match.

## 8. Things intentionally out of scope here

- The unary (non-streaming) `POST /transcription-model` REST endpoint — not used by us (P0 is streaming-only).
- `experimental_realtime` (bidirectional voice) — different feature, not transcription.
- Team scoping subprotocol — server-side concern already baked into the minted token.
