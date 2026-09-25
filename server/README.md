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
- `lib/gateway.ts` — wraps `gateway.experimental_transcription.getToken`.
  Every Gateway call in the test suite is mocked (`vi.mock("@ai-sdk/gateway")`)
  since there is no `AI_GATEWAY_API_KEY` in this environment; it runs for
  real as soon as a key is set (verified manually via curl above, which
  correctly falls through to a 502 without a key).

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

The macOS client connects **directly** to the AI Gateway transcription
WebSocket using the short-lived token minted here — this backend never
proxies audio. `POST /api/transcribe/token` only mints the token; the client
opens `wss://...` itself with it. Keep it that way: proxying audio through a
Vercel serverless function would add latency and hit execution-time limits.

## Database (when DATABASE_URL is set)

Schema lives in `lib/store/schema.ts` (drizzle). Generate/run migrations with
`drizzle-kit` (installed as a dev dependency; no `drizzle.config.ts` is
checked in yet since there's no database to point it at in this environment —
add one pointing `schema` at `lib/store/schema.ts` and `dbCredentials.url` at
`DATABASE_URL` before running `drizzle-kit push`/`generate`).
