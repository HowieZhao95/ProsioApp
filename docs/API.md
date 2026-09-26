# Prosio Backend API (v0.2 — adds /api/transcribe)

Base URL: `http://localhost:3000` in dev, Vercel deployment in prod. All bodies are JSON. Dates are ISO-8601 strings.

## Auth

Every endpoint except `/api/auth/dev` and `/api/health` requires `Authorization: Bearer <sessionToken>`.
`sessionToken` is a JWT (HS256, `PROSIO_JWT_SECRET`), claims: `sub` (user id), `email`, `exp` (30 days).
Real auth (Sign in with Apple / email via Better Auth) replaces `/api/auth/dev` later without changing the token shape.

Error shape for every non-2xx: `{ "error": { "code": "<code>", "message": "<human text>" } }`
Codes: `unauthorized` (401), `forbidden` (403), `quota_exceeded` (402), `bad_request` (400), `payload_too_large` (413), `unsupported_media_type` (415), `upstream_error` (502), `not_found` (404).

### `POST /api/auth/dev`
Only when `PROSIO_DEV_AUTH=1`, else 404.
Request `{ "email": "a@b.com" }` → `200 { "sessionToken": "…", "user": { "id": "…", "email": "…" } }`

### `GET /api/health`
`200 { "ok": true, "version": "0.1.0" }`

## Transcription token

### `POST /api/transcribe/token`
Request `{ "model": "google/gemini-3.5-transcribe-live" }` (optional; default that model; only allow-listed models accepted).
Checks entitlement + quota, then calls `gateway.experimental_transcription.getToken({ model })`.
→ `200 { "token": "…", "url": "wss://…", "model": "google/gemini-3.5-transcribe-live", "expiresAt": "…" }`
Errors: 401, 402 `quota_exceeded`, 400 model not allowed, 502 gateway failure.

## Batch transcription (P1.2: single-request cloud pass with routing + intent)

### `POST /api/transcribe`
Final, SMART-cleaned text for a complete recording. The client shows an on-device live preview meanwhile. Extended in P1.2 (docs/P1.2-AUDIO-ROUTING.md §3) to also decide, in the same request, whether the on-device transcript can be used as-is (skipping Gemini) and what the user wants done with it — backward compatible: every new field is optional.
Request:
```json
{ "audio": "<base64>", "audioFormat": "ogg-opus" | "wav", "mode": "smart",
  "vocabulary": ["Prosio"], "languageHints": ["zh-CN","en-US"], "sessionID": "uuid",
  "localTranscript": "…" | null, "hasSelection": false, "app": { "appName": "…", ... } | null }
```
`audioFormat`: `"wav"` (default, backward compatible — RIFF/WAVE, 16 kHz mono PCM16) or `"ogg-opus"` (Ogg container, Opus-encoded, per docs/P1.2-AUDIO-ROUTING.md §1 — mono; media type is auto-detected server-side from the file's magic bytes, no separate field needed). An unrecognized `audioFormat` value → `415 unsupported_media_type`. `mode`: `"smart"` (default) | `"verbatim"`. `vocabulary` ≤ 1000 terms. Max audio: 120 s for `wav`, 600 s for `ogg-opus` (Opus's much smaller size keeps the body well under Vercel's 4.5 MB limit even at 600 s); longer → 413 `payload_too_large`. `localTranscript` ≤ 4000 chars, optional.

**Flow when `localTranscript` is given:**
0. A cheap, deterministic, Jev-independent guard runs first (`server/lib/list-guard.ts`): if the transcript has ≥2 enumeration cues (第一/第二/第三/首先/其次/最后/一是/二是/first/second/third/finally/next) or ≥3 、/，/,-separated clauses following a colon or a list-intro cue (以下/几点/几件事/几个/points/things), it's treated as an unformatted spoken list and forced to the cloud path immediately (`reason: "needs-formatting"`, no Jev call at all) — Gemini SMART reliably turns spoken lists into Markdown (see docs/PROMPTS.md's formatting rules), but the on-device transcript never is, so this must never take the local fast path even if Jev would have called it "clean".
1. Otherwise, one Jev `evaluate()` call asking both the router's `clean`/`recognized` questions (see "Routing" below) and the intent classifier's question (docs/PROMPTS.md §5b) together — behind the shared circuit breaker (`server/lib/jev.ts`; a recent Jev failure/timeout means this returns "unavailable" immediately, no added latency). Only the criterion matching `hasSelection` is offered (`dictate` vs `edit`), same as `/api/intent`.
2. If the text is clean (`cleanProbability ≥ 0.9` — a stricter, separate threshold from `/api/route`'s 0.8, since skipping Gemini entirely is a stronger claim than just routing to SMART) **and** the classified intent is `dictate` or `edit` → return the local transcript as-is, **skip Gemini** (`source: "local"`). Usage is still metered by audio duration (no change to quota accounting), just no Gemini cost.
3. Otherwise, call Gemini as before (`source: "cloud"`). The local intent classification is reused (`classifiedOn: "local"`) unless it was `null` (Jev was unavailable) or the final text's leading ~6 non-punctuation characters differ from the local transcript's — in either case intent is reclassified on the final text instead (`classifiedOn: "final"`, one more Jev call, same breaker).

When `localTranscript` is omitted (old clients, or a genuinely unavailable local transcript), the server always takes the cloud path and always classifies intent on the final text (`classifiedOn: "final"`); `route` is `{ cleanProbability: null, reason: "no-local-transcript" }`.

Checks entitlement + quota, calls Gateway `transcribe({ model: 'google/gemini-3.5-transcribe', providerOptions: { google: { mode: 'SMART'|'VERBATIM', customVocabulary, languageCodes } } })` (skipped entirely on the local fast path).
Records usage server-side from the audio duration (idempotent on `sessionID`), so the client does NOT also call `/api/usage` for this path — this happens regardless of `source`.
→ `200 { "text": "…", "language": "zh" | null, "durationSeconds": 4.05, "source": "local" | "cloud", "intent": { "intent": "dictate"|"edit"|"ask"|"translate"|null, "confidence": number|null, "source": "jev"|"unavailable", "classifiedOn": "local"|"final" }, "route": { "cleanProbability": number|null, "reason": "clean"|"needs-cleanup"|"likely-misrecognized"|"router-error"|"no-local-transcript"|"needs-formatting" } }`
On the local fast path, `text` is exactly `localTranscript` and `language` is `null` (no Gemini call was made to determine it).
Errors: 401, 402 `quota_exceeded`, 400, 413 `payload_too_large`, 415 `unsupported_media_type`, 502 `upstream_error`. The routing/intent check itself never causes a 4xx/5xx — any Jev failure just falls through to the cloud path with `source: "unavailable"` fields, same as `/api/route` and `/api/intent`.

### `HEAD /api/transcribe`
No auth. `204`. Used by the client to pre-warm the TLS connection when dictation starts.

## Compose (P1: rewrite / translate / edit / ask)

### `POST /api/compose`
LLM text transformation. Prompts: docs/PROMPTS.md (verbatim, in `server/lib/prompts.ts`). Auth required.
Request (matches Swift `ComposeRequest`):
```json
{ "mode": "rewrite" | "translate" | "translateCommand" | "edit" | "ask",
  "text": "…", "selection": "…" | null, "scene": "general|email|chat|code|document",
  "targetLanguage": "en-US" | null,
  "app": { "bundleID": "…", "appName": "…", "windowTitle": "…", "url": "…" } | null,
  "vocabulary": ["Prosio"], "history": [{ "role": "user"|"assistant", "text": "…" }] }
```
`translateCommand` (docs/PROMPTS.md §2b): used when the intent classifier (`POST /api/intent`) decides a whole dictation is a spoken translate request (e.g. "帮我翻成日语：我们明天开会"); `text` is the full utterance (request + content together) and the model extracts both itself. `targetLanguage` is optional here (unlike plain `translate`, where it's required) — omitted means translate into the server's default language (currently `en-US`).
Validation: `text` 1–8000 chars; `selection` ≤ 20000 chars (required for `edit`); `targetLanguage` required for `translate` (optional for `translateCommand`); `history` ≤ 20 turns (ask only).
Response: **streamed plain text** (`Content-Type: text/plain; charset=utf-8`, chunked) — the output deltas in order. For non-ask modes the server applies output sanitation at the end (strip a wrapping pair of quotes / single wrapping code fence), so non-ask clients should use the complete body; ask clients render deltas live.
Headers: `Server-Timing` (auth, prompt, ttft, total) where possible, `X-Prosio-Model: <model id>`, `X-Prosio-Fallback: empty | drift` (non-ask only, present only when a guardrail fired — see below).
Model: env `PROSIO_COMPOSE_MODEL` / `PROSIO_ASK_MODEL` (ask only; falls back to `PROSIO_COMPOSE_MODEL`), default `openai/gpt-6-luna` for both (chosen from the live compose bake-off — cheapest tested, 100% robustness). For non-ask modes, two guardrails retry once with `PROSIO_COMPOSE_FALLBACK_MODEL` (default `openai/gpt-5.4-mini`) on luna's two observed failure modes: empty/whitespace output, or edit-mode content drift (fabricated code-fence/box-drawing/ASCII-art the selection didn't contain, or output > 3x the selection's length when the instruction didn't ask to expand). If the fallback also fails, the response is the original input unchanged (`text` for rewrite/translate, `selection` for edit) with `X-Prosio-Fallback` set accordingly.
Errors (before streaming starts): 400/401/402/502 structured as usual. Mid-stream upstream failure: the stream ends early and the client treats a truncated body as `ProsioError.network`.

## Intent classification (auto mode)

### `POST /api/intent`
Decides which mode a finished dictation is: `dictate` (type as-is), `edit` (apply to the current selection), `ask` (answer it), or `translate` (translate the spoken content). Uses Gateway model `typesafe-ai/jev` (same choice-question decision model as `/api/route`, no fixed keywords, any language). Runs on the on-device transcript at stop time, in parallel with cloud transcription — see docs/PROMPTS.md §5b.
Request: `{ "transcript": "…", "hasSelection": true|false, "app": { "appName": "…", ... } | null }` (`transcript` 1–4000 chars; `app` optional, only `appName` is used)
→ `200 { "intent": "dictate"|"edit"|"ask"|"translate"|null, "confidence": 0.0-1.0 | null, "source": "jev"|"unavailable", "latencyMs": 123 }`
Only the criterion matching `hasSelection` is offered to Jev (`dictate` when there's no selection, `edit` when there is; `ask` and `translate` are always offered).
Policy: take Jev's top choice only if its probability is ≥ 0.7 (`INTENT_CONFIDENCE_THRESHOLD`); below that, `intent` is the default (`dictate`, or `edit` with a selection) but `source` is still `"jev"` and `confidence` still reports the raw probability, since Jev did answer.
Jev error, an unexpected/unoffered answer, or no response within 1200 ms → `200 { intent: null, confidence: null, source: "unavailable", latencyMs }`. **The server does NOT fall back to an LLM.** In this case the client is responsible for applying its own bilingual (zh/en) rules-based fallback (`IntentRules` in ProsioCore; rules text in docs/PROMPTS.md §5b) — never blocking dictation.
Auth required. Not metered as audio usage. Never returns 5xx for classifier failures (only for auth/validation errors).

## Routing (auto mode)

### `POST /api/route`
Decides whether the on-device transcript can be inserted as-is or needs the cloud SMART pass. Uses Gateway model `typesafe-ai/jev` (a decision model: typed questions → typed answers + probabilities, 70–500 ms).
Request: `{ "localTranscript": "…", "vocabulary": ["Prosio"], "languageHints": ["zh-CN","en-US"] }` (`localTranscript` ≤ 4000 chars)
→ `200 { "needsCloud": true|false, "cleanProbability": 0.0-1.0 | null, "reason": "clean" | "needs-cleanup" | "likely-misrecognized" | "router-error", "latencyMs": 123 }`
Policy (server-side, conservative): `needsCloud = false` only when Jev's probability that the text is clean (no fillers/disfluencies, no self-corrections, no list/format needs, no likely recognition errors — esp. mangled mixed-language or dictionary terms) is ≥ 0.8. Any Jev error → `200 { needsCloud: true, reason: "router-error" }` (never block dictation).
Auth required. Not metered as audio usage.
Note: `POST /api/transcribe`'s P1.2 combined local-transcript check (below) asks this same `clean`/`recognized` question pair, but gates skipping Gemini entirely at a stricter, separately-configured 0.9 — this endpoint's own 0.8 threshold (gating the cheaper "route to SMART or not" decision) is unchanged.
Both endpoints — plus `POST /api/intent` and the combined check — share one Jev circuit breaker (`server/lib/jev.ts`): after any failure/timeout, further calls return the "unavailable"/"router-error" shape immediately for 60s before one probe retries.

## Usage

### `POST /api/usage`
Request `{ "sessionID": "uuid", "engineID": "gateway.gemini-3.5-transcribe-live", "audioSeconds": 12.3, "startedAt": "…" }`
→ `204`. Idempotent on `sessionID`.

### `GET /api/usage`
→ `200 { "periodStart": "…", "periodEnd": "…", "audioSecondsUsed": 123.4, "audioSecondsLimit": 3600 | null }`

## Dictionary

Entry shape (matches Swift `DictionaryEntry`): `{ "id": "uuid", "term": "Prosio", "note": null, "createdAt": "…", "updatedAt": "…" }`

### `GET /api/dictionary` → `200 { "entries": [Entry] }`
### `PUT /api/dictionary`
Request `{ "entries": [Entry] }` — full replace, last-write-wins by `updatedAt` per id. → `200 { "entries": [Entry] }`
Limit 1000 entries, term ≤ 100 chars.
