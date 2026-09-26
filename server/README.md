# Prosio Backend

Next.js (App Router, route handlers only) backend for Prosio, deployable to
Vercel as-is. Implements `docs/API.md` exactly.

## Setup

```bash
cd server
npm install
cp .env.example .env.local   # then fill in secrets
```

Env vars (see `.env.example`):

- `AI_GATEWAY_API_KEY` — Vercel AI Gateway key. Required for
  `POST /api/transcribe/token` to actually succeed. Without it, that one
  endpoint returns a structured `502 upstream_error`; every other endpoint
  works fine.
- `PROSIO_JWT_SECRET` — HS256 secret for session JWTs. Required.
- `PROSIO_DEV_AUTH` — set to `1` to enable `POST /api/auth/dev` (dev-only
  email → sessionToken sign-in, no real auth). Leave unset in production;
  the endpoint 404s when it isn't exactly `"1"`.
- `DATABASE_URL` — Neon/Postgres connection string. When unset, the backend
  falls back to an in-memory store (fine for local dev and for the test
  suite; state does not survive a restart and is not shared across serverless
  invocations — do not rely on it in production).

## Run

```bash
npm run dev        # http://localhost:3000
npm run build
npm run start
npm run typecheck  # tsc --noEmit
npm test           # vitest run
```

## Smoke test

```bash
curl localhost:3000/api/health

TOKEN=$(curl -s -X POST localhost:3000/api/auth/dev \
  -H 'content-type: application/json' -d '{"email":"you@example.com"}' \
  | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>console.log(JSON.parse(d).sessionToken))')

curl -s -X POST localhost:3000/api/transcribe/token \
  -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{}'
# -> 502 upstream_error if AI_GATEWAY_API_KEY isn't set, 200 { token, url, model, expiresAt } once it is.
```

## Architecture

- `lib/auth.ts` — signs/verifies session JWTs (`jose`, HS256). `requireUser(req)`
  reads the claims straight off the token (`sub` = user id, `email`); auth is
  fully stateless, no DB round-trip needed to authenticate a request.
- `lib/errors.ts` — the `{ error: { code, message } }` envelope and an
  `ApiError`/`withErrorHandling` pair every route uses.
- `lib/entitlements.ts` — stub: every user is on plan `"trial"` with a
  3600s/month audio quota. `TODO(P1): RevenueCat` marks where real
  plan/subscription lookups go.
- `lib/store/` — `Store` interface (`types.ts`) with two implementations:
  - `memory.ts` — in-memory, used when `DATABASE_URL` is unset.
  - `postgres.ts` + `schema.ts` — drizzle + `@neondatabase/serverless`.
    Type-checked but **not exercised** by the test suite (no live database in
    this environment) — see "What's unverified" below.
  - `index.ts` — `getStore()` picks the implementation based on `DATABASE_URL`.
- `lib/gateway.ts` — `mintTranscribeToken` (streaming token, `/api/transcribe/token`)
  and `transcribeBatch` (`experimental_transcribe` + `gateway.transcriptionModel`,
  `/api/transcribe`'s P0 batch path). Both wrap the same module-level `gateway`
  singleton from `@ai-sdk/gateway`, so its underlying HTTP keep-alive
  connections are reused across requests in a warm process — see the
  Latency section below. Every Gateway call in the test suite is mocked;
  it runs for real once `AI_GATEWAY_API_KEY` is set (live-verified).
- `lib/timing.ts` — `RequestTimer`, a tiny stage-duration accumulator.
  `POST /api/transcribe` uses it to emit a `Server-Timing` response header
  (`auth;dur=.., parse;dur=.., wav;dur=.., quota;dur=.., gateway;dur=..,
  total;dur=..`) and a matching debug `console.log` line on every request —
  cheap enough to leave on in production. `scripts/latency-bench.ts` reads
  the header to break down where request time actually goes.
- `POST /api/transcribe` defers its usage-store write to `next/server`'s
  `after()`, so a slow store write (e.g. a real Postgres write once
  `DATABASE_URL` is set) never adds to client-observed latency; the
  transcript is returned as soon as it's ready. Falls back to writing
  inline when called outside a real Next.js request scope (e.g. tests
  invoking the route handler directly), so this is transparent to callers
  either way — see `runAfterResponse` in the route file.
- `lib/router.ts` — `routeTranscript()`, `POST /api/route`'s auto-mode
  decision logic via Gateway model `typesafe-ai/jev`. Reuses `lib/gateway.ts`'s
  same keep-alive-tuned `gateway` client. Never throws: any error or a call
  over 1.5s (`ROUTER_TIMEOUT_MS`, via `AbortController`) resolves to
  `{ needsCloud: true, reason: "router-error" }` — see the Routing section
  below for the exact call shape and its live-calibration status.

### Routing (auto mode) — `POST /api/route`

Decides whether an on-device transcript can be inserted as-is, using
Gateway model `typesafe-ai/jev` ("System One": typed questions against a
shared state → typed answers + probabilities, ~70-500ms).

**Call shape — confirmed vs inferred** (full detail in `lib/router.ts`'s
header comment):

- **Confirmed** by reading the installed `ai@7.0.114` / `@ai-sdk/gateway@4.0.92`
  type definitions (the `evaluate` API — exported as `experimental_evaluate`
  from `"ai"` — and `gateway.evaluationModel("typesafe-ai/jev")` are already
  present; **no SDK upgrade was needed**) and **confirmed live** (see
  below — the request reached Gateway's real
  `POST /v4/ai/evaluation-model` endpoint and got back a structured,
  well-formed error, not a client-side shape error):
  `evaluate({ model: gateway.evaluationModel("typesafe-ai/jev"), state, questions })`,
  where `state` is a plain object (`{ transcript, languageHints, vocabulary }`
  here) and each question is `{ type: "boolean", instructions: "<statement>" }`,
  answered as `{ type: "boolean", probability: <P(true)> }`. No Jev-specific
  `providerOptions` exist in the SDK — it's driven entirely by this generic
  question/state protocol.
- **Inferred** (no web access in this environment to check TypeSafe's own
  docs): the task's "Noul (probability a statement is true)" is TypeSafe's
  own name for exactly what the AI SDK calls a `"boolean"` question — the
  shapes match exactly (a statement in, one probability out), so this is
  used with high confidence but isn't confirmed against TypeSafe's own
  documentation.

Two questions are asked per call (`lib/router.ts`): a primary one covering
everything docs/API.md's policy cares about (fillers, self-corrections,
lists, punctuation, likely recognition errors) — its probability is
`cleanProbability`, gated at `>= 0.8` for `needsCloud = false` — and a
narrower secondary one about recognition errors specifically, used only to
pick `reason` between `"needs-cleanup"` and `"likely-misrecognized"` when
the transcript isn't clean.

**Live calibration: blocked, not run.** `eval/route-cases.json` (23
hand-labelled transcripts: 11 clean, 12 needing cloud, zh/en/mixed) and
`scripts/route-eval.ts` (accuracy, false-clean rate, false-messy rate,
p50/p90 latency) are both written and ready. Running either against the
real Gateway in this environment gets:

```
GatewayInternalServerError: Your team has restricted access to this model.
Team owners can edit AI Gateway Settings (.../ai-gateway/settings) to
enable this model in Model Allowlist. Model: typesafe-ai/jev
```

— a 403 from `POST https://ai-gateway.vercel.sh/v4/ai/evaluation-model`
(`type: "no_providers_available"`, `resolvedProvider: "digitalocean"`,
`fallbacksAvailable: ["typesafe-ai"]`). This is a **Vercel AI Gateway
project setting** (Model Allowlist), not a code or request-shape problem —
the request reaches the right endpoint with a well-formed body and gets a
structured provider-side rejection, which is exactly what you'd expect if
the call shape were wrong in a *confusing* way it is not. **Action needed:
enable `typesafe-ai/jev` in the Vercel AI Gateway dashboard's Model
Allowlist for this project**, then run
`npx tsx --env-file=../.env.local scripts/route-eval.ts` and fold the
accuracy/false-clean-rate numbers in here.

Until then, `POST /api/route` is still safe to deploy: every call currently
resolves to `{ needsCloud: true, reason: "router-error" }` (the same
"always send to cloud" behavior as if this endpoint didn't exist), verified
by both the mocked test suite (`tests/route.test.ts`) and the live 403
above being caught by `routeTranscript`'s catch-all.

### Dictionary PUT semantics

`PUT /api/dictionary` is documented as "full replace, last-write-wins by
`updatedAt` per id". This implementation treats it as an **upsert merge**,
not a destructive replace of the whole set:

- For an id present in both the request and storage, the entry with the
  later `updatedAt` wins (ties go to the incoming request).
- Ids only in the request are added.
- Ids only in storage (not mentioned in this request) are **left alone**.

This is the only reading under which "last-write-wins by updatedAt" has any
work to do — a literal whole-set replace would make that clause meaningless,
since there would be nothing to compare against. It also means two devices
independently PUTting their full local dictionaries converge instead of one
clobbering the other. If the intent was actually a literal destructive
replace (delete anything not in the payload), that's a one-line change in
`Store.putDictionary`/`MemoryStore`/`PostgresStore` — flagged in the final
report as worth confirming.

## Deployment note (Vercel)

P0 architecture (as of 2026-09-26, see `docs/API.md` § Batch transcription):
the client records on-device, shows an on-device live preview, then sends
the complete recording to `POST /api/transcribe`, which forwards it to
Gateway batch `google/gemini-3.5-transcribe` (SMART) and returns the final
text. `POST /api/transcribe/token` (mint a client secret for the Gateway
*streaming* WebSocket) still exists and still works, but streaming was
live-tested and found unreliable (dropped segments); it's not the P0 path.
Neither path has this backend hold a persistent audio stream open end to
end — the batch path is one bounded request/response with the whole
recording, not a proxy.

### Latency

See the numbers below (`scripts/latency-bench.ts`). Three things matter more
than anything in `app/api/transcribe/route.ts` for `POST /api/transcribe`
latency, in the order they were found:

1. **Never benchmark or deploy-equivalent against `next dev`.** Dev mode's
   on-demand compilation/instrumentation made this route look like it added
   1-4s of overhead; in a production build (`next start` / Vercel, which
   never runs dev mode) the same route adds **single-digit milliseconds**
   (auth + body parse + WAV validation + quota check together average
   under 5ms) — essentially all of the request latency is the Gateway call
   itself, matching a direct in-process Gateway call to within ~100ms (plain
   HTTP+routing overhead of going through our server at all).
2. **Idle connections to the Gateway get re-handshaked.** Real dictation is
   almost always "first request after N seconds of nobody talking," not a
   tight loop, and Node/undici's *default* keep-alive is ~4s — far shorter
   than the gap between two dictation sessions. Measured on a long-running
   production server (`next start`), NOT cold-process restarts (a process
   restart's own variance — module load, first DNS lookup, TCP slow start —
   swamps this effect and is a different question):
   - **Before** any fix: first request after a 15s or 45s idle gap
     consistently cost **~1.1-1.6s more** than a request with no idle gap.
   - **After** giving the Gateway client its own `undici.Agent` with a 60s
     `keepAliveTimeout` (module-scope, `lib/gateway.ts`'s `gatewayAgent`):
     a 15s idle gap now shows **no measurable penalty** (in line with the
     warm baseline). A 45s gap still showed a penalty in about half of
     trials — our 60s client-side setting can't help once the *far end*
     (Gateway/its infra) has already closed the socket, which appears to
     happen somewhere under 60s; a 120s gap (well past any plausible
     server-side timeout) still showed a consistent, un-noisy ~1s penalty
     with this fix alone.
   - **After** additionally having `HEAD /api/transcribe` fire a
     fire-and-forget, deduped warm-up request (`getToken`, no audio/model
     inference) 1.5s before the client's real POST: the 120s-idle penalty
     disappeared (see table below) — the reconnect cost moves onto the
     HEAD, which the client already sends at key-down and the user never
     perceives as transcription latency, well before recording (≥1-2s)
     finishes.
   - An earlier attempt at HEAD warm-up (before the keep-alive agent
     existed) was A/B'd against **cold-process restarts** and showed no
     benefit — that was the wrong test; it doesn't tell you anything about
     the idle-connection case, which is the case that actually matters for
     real usage.

   | idle gap | prewarm? | client latency (ms) | gateway stage (ms) |
   |---|---|---|---|
   | 0 (back-to-back) | n/a | 2819 / 2950 / 3987 | ~2819-3987 |
   | 15s | no | 1777 / 2500 / 2599 | 1760 / 2486 / 2585 |
   | 45s | no | 2713 / 4241 / 5254 | 2685 / 4224 / 5241 |
   | 45s | yes | 3070 / 3099 / 6259 | 3056 / 3085 / 6242 |
   | 120s | no | 3592 / 3756 | 3566 / 3730 |
   | 120s | yes | **2896 / 2983** | **2883 / 2968** |

   (short16.wav, `next start -p 3200`, real `AI_GATEWAY_API_KEY`, 2-3
   trials/row — small samples, and the underlying Gemini call itself has
   real run-to-run variance (seen even at idle=0), so treat single outliers
   loosely; the 120s row is the cleanest signal because it's well past any
   plausible keep-alive window on either side. 45s is genuinely noisier in
   both directions, not just with prewarm — reproduce with
   `scripts/latency-bench.ts --idle 45 --n <more>` if you need a tighter
   read on that specific gap.)
3. **Vercel project settings that affect the Gateway call's own latency**
   (nothing here is configured by this repo — set these in the Vercel
   dashboard for the deployed project):
   - **Region**: deploy the function in a region close to where Gemini/the
     AI Gateway actually serves from (Vercel's AI Gateway is Cloudflare-
     fronted/global-edge for routing, but the underlying model call still
     has a real backend region; pick a US region unless/until you have data
     saying otherwise for this project — cross-region hops inside the
     Gateway's own routing are outside this backend's control, but an
     unnecessary extra hop from *your function's* region to the Gateway's
     ingress is not).
   - **Fluid Compute**: enable it. It keeps warm instances around and reuses
     them across invocations (including their in-memory module state, e.g.
     the `gateway` singleton and its HTTP keep-alive connections) far more
     aggressively than classic per-invocation Lambda, which matters a lot
     here since our own numbers show cold-vs-warm Gateway calls differing
     by 1-2s (see below) — Fluid Compute directly reduces how often a
     request pays that cold cost.
   - **`maxDuration`**: already set to `30` in `app/api/transcribe/route.ts`
     (`export const maxDuration = 30`). Batch SMART transcription measured
     at 1.5-4.3s for 4-10s clips; 30s gives headroom for the 120s max-length
     case and provider slowness without the function itself being killed
     mid-call.

## Database (when DATABASE_URL is set)

Schema lives in `lib/store/schema.ts` (drizzle). Generate/run migrations with
`drizzle-kit` (installed as a dev dependency; no `drizzle.config.ts` is
checked in yet since there's no database to point it at in this environment —
add one pointing `schema` at `lib/store/schema.ts` and `dbCredentials.url` at
`DATABASE_URL` before running `drizzle-kit push`/`generate`).
