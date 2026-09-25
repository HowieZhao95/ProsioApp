# Prosio Backend API (v0.2 — adds /api/transcribe)

Base URL: `http://localhost:3000` in dev, Vercel deployment in prod. All bodies are JSON. Dates are ISO-8601 strings.

## Auth

Every endpoint except `/api/auth/dev` and `/api/health` requires `Authorization: Bearer <sessionToken>`.
`sessionToken` is a JWT (HS256, `PROSIO_JWT_SECRET`), claims: `sub` (user id), `email`, `exp` (30 days).
Real auth (Sign in with Apple / email via Better Auth) replaces `/api/auth/dev` later without changing the token shape.

Error shape for every non-2xx: `{ "error": { "code": "<code>", "message": "<human text>" } }`
Codes: `unauthorized` (401), `forbidden` (403), `quota_exceeded` (402), `bad_request` (400), `payload_too_large` (413), `upstream_error` (502), `not_found` (404).

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

## Batch transcription (P0 final text)

### `POST /api/transcribe`
Final, SMART-cleaned text for a complete recording. The client shows an on-device live preview meanwhile.
Request:
```json
{ "audio": "<base64 of a RIFF/WAVE file, 16 kHz mono PCM16>", "mode": "smart", "vocabulary": ["Prosio"], "languageHints": ["zh-CN","en-US"], "sessionID": "uuid" }
```
`mode`: `"smart"` (default) | `"verbatim"`. `vocabulary` ≤ 1000 terms. Max audio 120 s (≈3.9 MB base64 — under Vercel's 4.5 MB body limit); longer → 413 `payload_too_large`.
Checks entitlement + quota, calls Gateway `transcribe({ model: 'google/gemini-3.5-transcribe', providerOptions: { google: { mode: 'SMART'|'VERBATIM', customVocabulary, languageCodes } } })`.
Records usage server-side from the audio duration (idempotent on `sessionID`), so the client does NOT also call `/api/usage` for this path.
→ `200 { "text": "…", "language": "zh" | null, "durationSeconds": 4.05 }`
Errors: 401, 402 `quota_exceeded`, 400, 413 `payload_too_large`, 502 `upstream_error`.

### `HEAD /api/transcribe`
No auth. `204`. Used by the client to pre-warm the TLS connection when dictation starts.

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
