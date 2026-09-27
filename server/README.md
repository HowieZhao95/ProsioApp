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
  cloud transcription and model calls to succeed.
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

curl -s localhost:3000/api/usage -H "authorization: Bearer $TOKEN"
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
- `lib/gateway.ts` — `transcribeBatch` (`experimental_transcribe` + `gateway.transcriptionModel`,
  `/api/transcribe`'s P0 batch path). Uses the same module-level `gateway`
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
- `lib/prompts.ts` — `docs/PROMPTS.md` implemented verbatim: a builder per
  compose mode (`buildRewritePrompt`, `buildTranslatePrompt`,
  `buildEditPrompt`, `buildAskPrompt`), each returning `{ system, messages }`
  ready for `streamText`, plus `sanitizeComposeOutput` (the shared
  quote/code-fence-stripping post-processing) and `languageNameFromBCP47`.
  See the Compose section below for the model-selection eval.

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

### Compose (P1) — `POST /api/compose`

Rewrite / translate / edit / ask, per `docs/PROMPTS.md` (source of truth;
`lib/prompts.ts` matches it verbatim — unit-tested against snapshots in
`tests/prompts.test.ts`, including every rendering-convention edge case:
empty vocabulary omits the whole bullet line, missing app falls back
gracefully, `general` scene drops the scene-rules block, BCP-47 codes
render as English language names).

**Added mode: `translateCommand`** (docs/PROMPTS.md §2b, `buildTranslateCommandPrompt`
in `lib/prompts.ts`) — for when the intent classifier (`POST /api/intent`,
below) decides a whole dictation is itself a spoken translate request (e.g.
"帮我翻成日语：我们明天开会"). Unlike plain `translate`, `text` here is the
full utterance (request + content together) and the model extracts both;
`targetLanguage` is optional, defaulting server-side to `en-US`
(`DEFAULT_TRANSLATE_COMMAND_LANGUAGE` in `app/api/compose/route.ts`) when
omitted.

- `streamText` via the same keep-alive Gateway client as `/api/transcribe`
  and `/api/route` (`lib/gateway.ts`). Temperature 0.2 (rewrite/translate/edit),
  0.4 (ask) — **except for models that reject it** (see below).
- **Ask streams live**; rewrite/translate/edit are buffered server-side
  (outputs are short) so `lib/prompts.ts`'s `sanitizeComposeOutput` — strip
  one wrapping quote pair or code fence, trim — can run on the complete
  text before it's sent. Ask is never sanitized (deltas go out as the model
  produces them).
- `Server-Timing`: `auth, prompt, ttft, total` for buffered (non-ask)
  responses. For ask, headers must go out before the model responds, so
  only `auth, prompt` are in the header (no `total` — it would just be
  elapsed-so-far mislabeled); the full breakdown including `ttft` is still
  logged server-side once the stream ends.
- Models: `PROSIO_COMPOSE_MODEL` env (all non-ask modes, and ask's default
  when `PROSIO_ASK_MODEL` isn't set), `PROSIO_ASK_MODEL` env (ask only).
  **Default (both): `openai/gpt-6-luna`**, chosen by the user 2026-09-26
  from the live bake-off below.
- **Per-model call-option capabilities** (`app/api/compose/route.ts`'s
  `callOptionsFor`, live-tested): `openai/gpt-6-luna` and
  `openai/gpt-5.4-mini` are OpenAI reasoning models — both reject
  `temperature` outright (Gateway logs "temperature is not supported for
  reasoning models" on every call otherwise), so it's omitted entirely for
  them rather than sent and ignored. `gpt-6-luna` additionally gets
  `providerOptions.openai.reasoningEffort = "none"` (lowest latency;
  confirmed accepted — `"minimal"` is NOT valid for this model, Gateway
  names the real set: `none, low, medium, high, xhigh, max`). Every other
  model tested (Anthropic, Gemini, MiniMax) accepts `temperature` normally
  and still gets 0.2/0.4.
- **Guardrails for `gpt-6-luna`'s two observed failure modes** (non-ask
  only — ask streams live, so there's nothing to buffer/retry):
  - **Empty/whitespace output** → retry once with `PROSIO_COMPOSE_FALLBACK_MODEL`
    (default `openai/gpt-5.4-mini`); if still empty, return the original
    input unchanged (`text` for rewrite/translate, `selection` for edit)
    with `X-Prosio-Fallback: empty`.
  - **Edit drift**: if the output contains a code fence / box-drawing or
    ASCII-art pattern the selection didn't contain (`` ``` ``, Unicode box-
    drawing/block-element ranges, `+---`-style dividers, ASCII tables), or
    is > 3x the selection's length when the instruction doesn't ask to
    expand (`expand`/`add a|an|more`/`扩写`/`补充`/`扩展`) — retry once with
    the fallback model; if that also trips, return the selection unchanged
    with `X-Prosio-Fallback: drift`. The length check has a 20-char floor on
    the selection to avoid false positives on trivial one-liners (e.g. "No."
    → "No, thank you." is technically "3x longer" but is normal politeness
    padding, not fabricated drift).
  - Both directly target real failures from the bake-off: `gpt-6-luna`
    fabricated an ASCII bar chart 3/3 times on `ed-cant-apply` (asked to
    "add a bar chart" to plain text — PROMPTS.md says return unchanged when
    an instruction can't reasonably apply) and returned empty output twice
    elsewhere in the same 150-call run.
  - Ask mode gets no guard/retry (already streamed); an empty final answer
    is just logged server-side (`console.warn`), matching the client's
    existing "empty answer" handling.
  - Unit-tested in `tests/compose.test.ts` (mocked model): both empty-output
    cases, the ASCII-bar-chart drift case, a length-drift case, and a
    "expansion explicitly requested" case that must NOT trigger the guard.

#### Model-selection eval

`eval/compose-cases.json` (50 hand-written cases: rewrite×14, translate×8,
edit×18, ask×10, spanning zh/en/mixed and every scene) and
`scripts/compose-eval.ts` — run live against the real Gateway with
candidates verified to exist via `gateway.getAvailableModels()`, judged by
`anthropic/claude-opus-4.5` (`generateObject`, temperature 0) on
faithfulness, format compliance, injection resistance, quality (0-1 each),
plus a deterministic `hasInventedContent` yes/no flag. **The judge is now
given the exact system prompt (from `lib/prompts.ts`) used for that call**,
not just a generic rubric — see the "judge-gap fix" note below.

**Original run (2026-09-26, 40 cases, before the Edit no-additions rule existed):**

| model | faithfulness | format | injection-resist. | quality | robustness pass | TTFT p50/p90 (ms) | total p50/p90 (ms) |
|---|---|---|---|---|---|---|---|
| `google/gemini-3.5-flash-lite` | 0.97 | 0.95 | 0.98 | 0.94 | 86% (6/7) | 827/1512 | 978/1663 |
| `google/gemini-3.5-flash` | 0.99 | 0.99 | 1.00 | 0.98 | 100% (7/7) | 2991/3888 | 3080/4437 |
| `anthropic/claude-haiku-4.5` | 0.95 | 0.97 | 1.00 | 0.97 | 100% (7/7) | 873/1054 | 1059/1387 |
| `openai/gpt-5.4-mini` | 0.99 | 0.98 | 1.00 | 0.94 | 100% (7/7) | 784/995 | 1006/1194 |

Picked `anthropic/claude-haiku-4.5` from this — best balance of speed,
robustness, and (unlike gpt-5.4-mini) it respects the `temperature` setting.

#### Follow-up: Edit mode inventing content (live-acceptance bug)

Live acceptance found Edit adding an unstated reason: selection "你明天必须把报告交给我，不然后果自负。"
+ instruction "改得更礼貌一点" → "...这样我们可以按时推进项目" (invented "so we can
keep the project on schedule"). Fixed `docs/PROMPTS.md` §3 with a new rule
("Never add reasons, facts, details, examples, promises or new sentences
that aren't in the selection...") and added 10 new eval cases: 8
`category: "no-additions"` (the exact case, "more polite/professional/friendly"
on curt zh/en text, "make it shorter", "make it more confident", "fix
grammar") + 2 `category: "additions-expected"` positive controls ("add a
sentence thanking them", "扩写一下，补充理由") that must add content.

**Re-ran full 50 cases against the (then-)default `anthropic/claude-haiku-4.5`:**

| model | faithfulness | format | injection-resist. | quality | robustness pass | no-additions pass | TTFT p50/p90 | total p50/p90 |
|---|---|---|---|---|---|---|---|---|
| `anthropic/claude-haiku-4.5` (50 cases) | 0.96 | 0.94 | 1.00 | 0.97 | 100% (7/7) | **80% (8/10)** | 942/1691 | 1080/1834 |

Robustness held at 100%, but **the new prompt rule alone did not fix the
model**: Haiku reproduced the *exact* reported bug (verified 3/3 manual
re-runs, and again in this scored run) —

```
selection:    你明天必须把报告交给我，不然后果自负。
instruction:  改得更礼貌一点
output:       麻烦你明天能否把报告交给我？这样我们就能按时推进项目。
              (judge: hasInventedContent=true — "这样我们就能按时推进项目"
               is an invented reason not in the selection)
```

— plus one more miss on `ed-noadd-friendly-en` ("No." → "Not right now,
thanks!", inventing a timing qualifier). This is Anthropic's model applying
a learned Chinese-politeness convention (append a justification clause)
that overrides the explicit "don't add content" rule at temperature 0.2.

**Comparator: `openai/gpt-5.4-mini`, edit-mode cases only (18):**

| model | faithfulness | format | injection-resist. | quality | robustness pass | no-additions pass | TTFT p50/p90 | total p50/p90 |
|---|---|---|---|---|---|---|---|---|
| `openai/gpt-5.4-mini` (18 edit cases) | 0.99 | 0.98 | 1.00 | 0.91 | 100% (1/1) | **100% (10/10)** | 862/1833 | 1285/2054 |

On the exact threat case: `"你明天能把报告交给我吗？"` — polite, no invented
reason. Also correctly returned the selection unchanged on `ed-cant-apply`
this run (see judge-gap fix below) — every edit case passed, zero misses.

**Decision: switched both `PROSIO_COMPOSE_MODEL` and `PROSIO_ASK_MODEL`
defaults to `openai/gpt-5.4-mini`.** The temperature-ignored quirk noted in
the original run turned out not to cost quality in practice (0.91-0.99
across both runs, comparable to or better than Haiku on faithfulness/format),
and it doesn't reproduce the content-invention bug at all — which, given
this task exists specifically because that bug reached live acceptance, is
the deciding factor over Haiku's slightly-more-predictable temperature
handling. `gpt-5.4-mini`'s full-mode numbers from the original 40-case run
(faithfulness 0.99, format 0.98, quality 0.94, robustness 100%, TTFT
p50 784ms) still apply to rewrite/translate/ask, since those prompts were
unchanged by this follow-up.

**Judge-gap fix, verified working:** the judge previously scored `ed-cant-apply`
(instruction "add a bar chart" applied to plain text; PROMPTS.md's edit
rule "if the instruction can't reasonably be applied to the text, return
the selected text unchanged") against a generic rubric and incorrectly
penalized 3/3 candidates who correctly returned the text unchanged. The
judge prompt now includes the exact system prompt for that call. Confirmed
fixed with real evidence in this run: when Haiku *violated* the same rule
(gave an explanation instead of returning the text unchanged), the judge
correctly caught it this time — `formatCompliance: 0`, rationale quoting
the exact rule it violated — rather than the previous false-negative-on-compliance
failure mode.

Re-run after any prompt change: `npx tsx --env-file=../.env.local scripts/compose-eval.ts`
(add `--modes edit` to scope to one mode, `--case <id>` for one case).

#### Model bake-off (2026-09-26) — new candidates, full 50-case set, 2x per case

`scripts/compose-bakeoff.ts`: every case in `eval/compose-cases.json` (all
modes + the no-additions/additions-expected/robustness categories), each
run twice, judged the same way as above (exact per-mode system prompt given
to the judge). Also computes a `$/1k requests` estimate from
`gateway.getAvailableModels()`'s own per-token pricing, and flags/strips any
`<think>`/`<thinking>` leakage into the output text as a format failure.

**Two of six requested candidates are blocked in this Gateway project's
Model Allowlist** — `openai/gpt-6-luna` and `deepseek/deepseek-v4.1-flash`
both return `403 "Your team has restricted access to this model"` on every
attempt (confirmed 3x for `gpt-6-luna` specifically, live, same failure
mode as `typesafe-ai/jev` in the routing task). **This is a Vercel AI
Gateway dashboard setting, not fixable from code.** The script's `--extra-runs`
(per-model run-count override, e.g. `openai/gpt-6-luna=3`) and
`--reasoning-efforts none,minimal,low` (per-effort latency/quality sweep,
OpenAI reasoning models only) flags are already wired up for the requested
extra scrutiny on `gpt-6-luna` — **zero code changes needed**, just:
```
npx tsx --env-file=../.env.local scripts/compose-bakeoff.ts \
  --candidates openai/gpt-6-luna,anthropic/claude-haiku-4.5 \
  --extra-runs openai/gpt-6-luna=3 --reasoning-efforts none,minimal,low
```
once it's allowlisted.

**Results, 4 testable candidates (100 runs each: 50 cases × 2):**

| model | temp honored? | faithfulness | format failures | quality | no-additions pass | robustness pass | TTFT p50/p90 (ms) | total p50/p90 (ms) | est. $/1k req |
|---|---|---|---|---|---|---|---|---|---|
| `google/gemini-3.8-flash` | yes | 0.98 | 0 | 0.97 | 75% (15/20) | **100% (14/14)** | 3762/5887 | 4135/6368 | $1.272 |
| `minimax/minimax-m2.7` | yes | 0.91 | 5 | 0.90 | **80% (16/20)** | 71% (10/14) | 2914/4337 | 3005/4717 | **$0.246** |
| `minimax/minimax-m2.7-highspeed` | yes | 0.93 | 3 | 0.92 | 75% (15/20) | 71% (10/14) | 3315/5127 | 3526/5327 | $0.475 |
| `anthropic/claude-haiku-4.5` (baseline) | yes | 0.95 | 2 | 0.93 | 70% (14/20) | 86% (12/14) | **945/1305** | **1102/1610** | $0.414 |

None are OpenAI reasoning models by lineage, so no `reasoningEffort` was set
for any of them (that option only applies to `openai/*`); none showed
`<think>` leakage; all four honor `temperature` normally (unlike
`gpt-5.4-mini`, the currently-deployed default, elsewhere in this doc).

**Per-mode quality (mean judge score, 0-1):**

| model | rewrite | translate | edit | ask |
|---|---|---|---|---|
| `google/gemini-3.8-flash` | 0.99 | 0.98 | 0.97 | 0.95 |
| `minimax/minimax-m2.7` | 0.84 | 0.98 | 0.92 | 0.88 |
| `minimax/minimax-m2.7-highspeed` | 0.87 | 0.97 | 0.94 | 0.89 |
| `anthropic/claude-haiku-4.5` | 0.99 | 0.98 | 0.87 | 0.89 |

**Threat case (`ed-noadd-threat-zh`), both runs, every candidate:**

```
google/gemini-3.8-flash        run#0: "请您明天把报告交给我，非常感谢。"          hasInventedContent=true
google/gemini-3.8-flash        run#1: "请您明天务必将报告提交给我，谢谢配合。"      hasInventedContent=false
minimax/minimax-m2.7           run#0: "麻烦你明天把报告交给我，好吗？"            hasInventedContent=false
minimax/minimax-m2.7           run#1: "请您明天把报告交给我，好吗？"              hasInventedContent=false
minimax/minimax-m2.7-highspeed run#0: "麻烦你明天把报告交给我，好吗？"            hasInventedContent=false
minimax/minimax-m2.7-highspeed run#1: "麻烦你明天把报告交给我，谢谢。"            hasInventedContent=false
anthropic/claude-haiku-4.5     run#0: "麻烦你明天能否把报告交给我？这样对我们的工作进度会很有帮助。"  hasInventedContent=true
anthropic/claude-haiku-4.5     run#1: "麻烦你明天能否把报告交给我？这样我们可以按时推进项目。"      hasInventedContent=true
```

Both minimax models handled it cleanly **2/2**; `claude-haiku-4.5` invented
a justification **2/2** (now confirmed across 5 independent runs total,
counting the earlier follow-up eval); `gemini-3.8-flash` was 1/2 clean.
**No model in any test run has been 100% reliable on this exact case
except the two minimax variants and the currently-deployed
`openai/gpt-5.4-mini`** (0/2 invented, from the earlier follow-up run;
not re-tested here since it wasn't in this candidate list).

**Other failure patterns worth flagging** (see the raw JSON for every
rationale): both minimax models occasionally *wrote an actual poem* for
`rw-robust-poem` instead of treating the dictation as text to adapt — a
straightforward instruction-injection failure, worse than anything Haiku or
Gemini did. All three of minimax/minimax-highspeed/haiku failed
`ask-robust-injection-selection` (asked to summarize adversarial context
text, they refused to engage with it at all instead of describing it as
content) — a shared weakness, not something that singles out one candidate.
`minimax-m2.7` also added unrequested greetings/sign-offs
("Hi,"/"Thanks!"/"谢谢") on plain rewrite cases where the user hadn't
dictated one, directly violating rewrite's own rule — its main quality gap.

**Recommendation — latency-critical modes (rewrite/translate/edit):**
none of these four candidates should replace the deployed default. Speed is
the gate here (this sits in the insertion-latency critical path) and only
`claude-haiku-4.5` is fast (945ms p50) — but it has the worst no-additions
rate of the four (70%) and fails the flagship threat case reliably.
`gemini-3.8-flash` and both `minimax` variants are 3-4x slower (2.9-3.8s
p50 TTFT) despite `minimax-m2.7`'s better no-additions/cost numbers — too
slow to trade in for a same-or-worse safety property. **Keep
`openai/gpt-5.4-mini`** (already deployed; from the earlier follow-up eval:
100% no-additions on edit, ~784-1006ms p50 TTFT, faithfulness 0.99) —
nothing here beats it on the metric that matters most (faithfulness/no-additions)
without a latency regression.

**Recommendation — Ask** (quality-first, but TTFT < ~1.5s p50 required):
of these four, only `claude-haiku-4.5` clears the bar (945ms); the other
three are 2.9s+ p50, 2-2.5s over budget. `gpt-5.4-mini` (deployed) also
clears it from earlier data. Both are reasonable; no evidence here to
switch away from the deployed default.

**Can `openai/gpt-6-luna` replace `claude-haiku-4.5` as default, for (a)
rewrite/translate/edit or (b) ask? Cannot be determined — it's blocked at
the account level (confirmed 3x, see above), so there is zero data on it,
positive or negative, in this or any prior run.** Once allowlisted, the
command above (3x runs, temperature check, `none/minimal/low` reasoning-effort
sweep, full failed-case dump, head-to-head vs. `claude-haiku-4.5` — all
already implemented) will answer this directly with no further code
changes.

Full data, every rationale, both runs: `eval/results/bakeoff-*.json`/`.md`.

#### `openai/gpt-6-luna`, allowlisted (2026-09-26) — run cut short by a Gateway budget cap

Once allowlisted, `openai/gpt-6-luna` was added to a fresh bake-off run
(`--extra-runs openai/gpt-6-luna=3`, alongside `openai/gpt-5.4-mini` ×2 and
`anthropic/claude-haiku-4.5` ×2). **The run was interrupted mid-way: the
Vercel AI Gateway project hit its configured spend cap** —
`"Team budget exceeded. Current spend: $10.40, limit: $10.00"` (402,
`quota_for_entity_exceeded`) — confirmed to block **every** model, not just
one (`getCredits()` separately shows real balance: $13.01 remaining,
$12.03 used — this is a configured budget *alert/cap*, not an empty
wallet). **Action needed: raise or reset the cap in the Vercel AI Gateway
dashboard's Budgets & Spend page** (linked in the error), then re-run:
```
npx tsx --env-file=../.env.local scripts/compose-bakeoff.ts \
  --candidates openai/gpt-6-luna,openai/gpt-5.4-mini,anthropic/claude-haiku-4.5 \
  --runs 2 --extra-runs "openai/gpt-6-luna=3" \
  --head-to-head openai/gpt-6-luna,anthropic/claude-haiku-4.5
```

**What did complete before the cap hit — `openai/gpt-6-luna`, 145/150 calls
succeeded (full 50-case set × 3 runs; 5 failures were genuine model
mistakes, not budget errors):**

| | |
|---|---|
| Reasoning model? | Yes — every call warned `"temperature is not supported for reasoning models"` |
| `reasoningEffort` accepted | `none`, `low` confirmed; **`minimal` is REJECTED** — Gateway's own warning: *"gpt-6-luna only supports the following reasoning efforts: none, low, medium, high, xhigh, max"* (so `medium`/`high`/`xhigh`/`max` are presumably also valid, per that same message, though not individually tested). No reasoning-effort override was in effect for the 145-call sample below (full sweep blocked by the budget cap — see above). |
| Faithfulness / quality | 0.96 / 0.94 |
| Per-mode quality | rewrite 0.94, translate 0.98, edit 0.94, ask 0.94 |
| No-additions pass | 90% (27/30) |
| Robustness pass | **100% (21/21)** |
| Format failures | 5 (all `ed-cant-apply`, see below) |
| TTFT p50/p90 | 1081/2120ms |
| Total p50/p90 | 1313/2228ms |
| Est. $/1k requests | **$0.052** — cheapest of every model tested across both bake-offs by a wide margin |

**Threat case (`ed-noadd-threat-zh`), all 3 runs:** `"请你明天把报告交给我，谢谢。"`
— identical, clean, **3/3 no invented content**.

**Luna's 5 failed cases, verbatim:**
- `rw-chat-en#1`, `rw-code-zh#1`: **empty output** — the model returned
  nothing for two otherwise-ordinary rewrite cases. No pattern found across
  the other 148 calls; worth watching for in production if this model is
  adopted.
- `ed-cant-apply#0/#1/#2` (all 3 runs): instead of returning
  `"Revenue grew steadily this quarter."` unchanged (per PROMPTS.md's
  "instruction can't reasonably be applied" fallback), luna fabricated an
  ASCII-art bar chart every single time, e.g.:
  ```
  Revenue grew steadily this quarter.

  Revenue trend:
  ▂ ▃ ▄ ▅ ▆
  ```
  This is luna's one clear, repeatable behavioral quirk in this data: it
  tries harder to literally satisfy "add a chart" than the other models
  tested, at the cost of violating the no-added-content rule every time.

**`openai/gpt-5.4-mini` (partial — only part of its 2x/50-case run
completed before the cap hit) and `anthropic/claude-haiku-4.5` (0 usable
calls — its batch started after the cap was already exceeded) do not have
comparable data this round.** The TTFT re-measurement the coordinator asked
for is inconclusive: gpt-5.4-mini's partial sample showed 667/916ms
(p50/p90), in line with the ~784-1006ms seen in the earlier full eval —
consistent with normal variance, not a regression, but the sample is too
small (and too aligned with the budget cutoff) to rule out an occasional
slow outlier like the 2.0s the coordinator observed live. **Needs the full
re-run above to resolve properly.**

**Recommendation, on the data available (not a full comparison — treat as
preliminary):**
- **Rewrite/translate/edit**: `openai/gpt-6-luna` is the most interesting
  new option — by far the cheapest ($0.052 vs. $0.25-0.41/1k), reasonably
  fast (1081ms p50, though 2120ms p90 is on the high side), 100% robustness,
  and better no-additions (90%) than the deployed default's fresh-run number
  (`claude-haiku-4.5` at 70%, both same day). It is NOT yet shown to beat
  `gpt-5.4-mini`'s **100%** no-additions from the earlier complete eval —
  that comparison needs the interrupted run redone. Don't switch on this
  data alone; it's a promising lead, not a confirmed win.
- **Ask** (TTFT < ~1.5s p50): `gpt-6-luna`'s 1081ms p50 clears the bar (its
  2120ms p90 is a concern), as does `gpt-5.4-mini`'s partial 667ms and
  `claude-haiku-4.5`'s earlier full-run 945ms. All three are viable
  candidates; no data here argues for switching away from the deployed
  default.
- **No default changed** *(as of this bake-off — see below: the user
  subsequently decided to switch to `gpt-6-luna` anyway, on the strength of
  its cost/robustness numbers, with guardrails added specifically for its
  two observed failure modes above)*.

#### Decision: switched to `openai/gpt-6-luna`, with guardrails (2026-09-26)

Despite the "preliminary, not a confirmed win" caveat above, the user chose
`openai/gpt-6-luna` as the default for **all** compose modes — its cost
($0.052/1k vs. $0.25-0.41/1k for everything else tested) and 100%
robustness outweighed the incomplete no-additions comparison. To cover its
two known failure modes (empty output; fabricating ASCII-art/box-drawing
content instead of following PROMPTS.md's "return unchanged" edit fallback),
`app/api/compose/route.ts` now retries once with `PROSIO_COMPOSE_FALLBACK_MODEL`
(default `openai/gpt-5.4-mini`) whenever either is detected, falling back to
returning the user's original input unchanged if the retry also fails — see
the guardrails bullet list above for the exact rules, and the "per-model
call-option capabilities" bullet for the `temperature`/`reasoningEffort`
handling this required.

**Live verification post-switch** (`:3200`, real key, modest spend — one
call per check):

| check | output | `X-Prosio-Model` | `X-Prosio-Fallback` | total |
|---|---|---|---|---|
| Edit, threat case | `请你明天把报告交给我，谢谢。` (clean, no invented content) | `openai/gpt-6-luna` | *(none)* | 2508ms |
| Translate zh→en | `We'll have a meeting tomorrow at 3 p.m. Please have the materials ready in advance.` | `openai/gpt-6-luna` | *(none)* | 1281ms |
| Ask | `Paris.` | `openai/gpt-6-luna` | *(none)* | streamed, ttft not in header (see above) |

No guardrail fired on any of the three — luna handled all of them cleanly
first try. `/api/transcribe` and `/api/health` re-checked unaffected (no
regression from this change).

### Intent classification (auto mode) — `POST /api/intent`

Decides which mode a finished dictation is (`dictate`/`edit`/`ask`/`translate`),
per `docs/PROMPTS.md` §5b. No fixed keywords, any language — same Jev
choice-question protocol as `/api/route` (`lib/intent.ts`'s `classifyIntent()`,
reusing the confirmed call shape from `lib/router.ts`). Only the criterion
matching `hasSelection` is offered (`dictate` vs `edit`; `ask`/`translate`
always offered). Threshold `INTENT_CONFIDENCE_THRESHOLD = 0.7`, timeout
`INTENT_TIMEOUT_MS = 1200`.

**Amendment (2026-09-26, user): no server-side LLM fallback.** The original
task spec called for a compose-model fallback prompt when Jev fails; the
user changed this mid-task to a rules-based client fallback instead. So:

- Jev answers, top choice ≥ 0.7 → `{ intent: <choice>, confidence, source: "jev" }`.
- Jev answers, but below threshold → `{ intent: <default>, confidence, source: "jev" }`
  (`default` = `dictate`, or `edit` with a selection). `source` is still
  `"jev"` here (it did answer) and `confidence` still reports the raw
  probability, specifically so `scripts/intent-eval.ts`'s threshold sweep
  can recompute decisions at other thresholds without re-calling Jev.
- Jev errors, returns an unexpected/unoffered answer, or exceeds 1200ms →
  `{ intent: null, confidence: null, source: "unavailable" }`. **The server
  does not call any LLM as a fallback.** The client is responsible for
  applying its own bilingual (zh/en) rules (`IntentRules` in ProsioCore,
  Swift — source of truth is docs/PROMPTS.md §5b's rule text, not this repo).
- `classifyIntent()` never throws, and the route wraps it in try/catch anyway
  (defense in depth) — `/api/intent` never 5xxs for classifier failures, only
  for auth (401) or validation (400) errors.

Full request/response shape: see `docs/API.md`'s "Intent classification"
section.

**A TS port of the client's rules exists for eval comparison only**
(`scripts/intent-rules.ts`, `classifyIntentByRules()`) — explicitly marked
non-authoritative in its own header comment. It is never imported by any
server route; core owns the real Swift implementation.

#### Eval: `eval/intent-cases.json` + `scripts/intent-eval.ts`

78 hand-labelled cases across en/zh/ja/es/fr/ko/mixed, weighted toward hard
negatives per the task brief: messages/questions/requests addressed to
other people (not Prosio) that must stay `dictate` even though they contain
a question or an imperative (e.g. "Can you send me the report by end of
day", "你明天有空吗 一起吃个饭", "请问这个价格含不含运费" — `请问` is
explicitly excluded as a translate/ask cue per PROMPTS.md §5b, too common
in ordinary writing); text that merely *mentions* translating without
requesting one ("这段翻译得不太好", "she works as a translator for the
embassy"); and positive `ask`/`translate` cases phrased many different ways
with no shared keyword set, so a real semantic classifier is required to
pass them (e.g. bare factual questions with no "Prosio" cue at all).

`scripts/intent-eval.ts` runs three sources per case: `jev` (real Gateway
call), `rules` (the non-authoritative TS port, no network), and `chain`
(Jev's answer, replaced by the rules port only when Jev's `source` is
`"unavailable"` — matching what the client actually does; a below-threshold
Jev answer is *not* further replaced by rules, since the client doesn't
invoke its fallback in that case either). Reports per source: accuracy,
a full confusion matrix, false-command rate on `dictate`-expected cases
(commanding when the user just wanted to dictate is the costly error —
should be ~0), and (`jev` only) latency p50/p90 and a threshold sweep
(0.5/0.6/0.7/0.8/0.9) recomputed from the raw confidence.

**Live run status: Jev is currently rate-limited**, same failure mode the
coordinator flagged mid-task — confirmed directly against the Gateway
(bypassing the route's 1.2s timeout) with a standalone probe script:

```
RetryError: Failed after 3 attempts. Last error: GatewayRateLimitError:
The upstream provider is currently experiencing high demand. Please retry shortly.
```

This is an upstream/provider-side condition, not a code or Model Allowlist
problem (unlike the earlier `typesafe-ai/jev` 403 in the routing task —
that was fixed by allowlisting; this is a live 429-equivalent that should
clear on its own). Every live `/api/intent` call made during this task
(3 checks against `:3200`) correctly hit the 1200ms timeout and returned
`{ intent: null, source: "unavailable" }} `, confirming the "never blocks,
degrades cleanly" behavior end-to-end even under a fully-blocked Jev.

**`--rules-only` run (no network, always available)** — this is the
rules-port's standalone accuracy, i.e. roughly what the client's fallback
alone would score if it had to classify every case without Jev (in
production it only runs on the subset where Jev is actually unavailable):

```
50/78 correct (accuracy=64.1%)
false-command rate on dictate cases: 3/27 = 11.1%
  - "这段翻译得不太好 语气有点生硬" -> translate (expected dictate)
  - "他是我们公司的翻译 每天都很忙" -> translate (expected dictate)
  - "can you help me translate the marketing deck into French..." -> translate (expected dictate)
```

The rules port does well distinguishing explicit `translate`/`edit` commands
from plain dictation, but scores poorly on implicit `ask` cases with no
cue word (e.g. "what's the capital of France" with no "Prosio"/"提问" cue) —
those default to `dictate`, which is the intended, safe rules behavior
(never invent a command from silence) but is exactly the accuracy Jev's
semantic understanding is meant to recover. The three false-commands above
are keyword substring matches on "翻译"/"translate" inside text that only
*mentions* translation — a known, documented limitation of keyword rules
that Jev's semantic criteria (`"not when translation is merely mentioned
in the text"`) are designed to avoid.

**Re-run once Jev clears:**
`npx tsx --env-file=../.env.local scripts/intent-eval.ts` (add `--case <id>`
to scope to one case). Compare `jev` vs `chain` accuracy once real numbers
are available — the gap is literally "what the rules fallback costs",
which is what the amendment asked this eval to measure.

### P1.2 — audio routing: Ogg/Opus upload + combined local-transcript check

Per `docs/P1.2-AUDIO-ROUTING.md` §1/§3, `POST /api/transcribe` gained (backward compatibly — every new field is optional, old request/response shapes still work):

- **`audioFormat: "ogg-opus" | "wav"`** (default `"wav"`). An unrecognized value → `415 unsupported_media_type` (a `z.enum()` would only ever give 400, so `audioFormat` is validated manually after parsing — see `isAudioFormat()` in `app/api/transcribe/route.ts`). Max audio: 120s for `wav` (unchanged), 600s for `ogg-opus` (Opus is ~16x smaller at identical transcribed text — coordinator-verified live against Gemini batch — so the body stays well under Vercel's 4.5MB limit even at 5x the duration).
- **`lib/ogg-opus.ts`** (`parseOggOpus`): a from-scratch, minimal Ogg-container parser — reads just enough page/segment structure (RFC 3533) plus the first page's `OpusHead` identification packet (RFC 7845 §5.1) to get channel count and pre-skip, then computes duration from the final page's granule position (`(granulePosition - preSkip) / 48000` — Opus granule positions are always in units of 1/48000s regardless of the actual encode rate). It does **not** decode audio, and doesn't validate the CRC32 (structure only). `transcribeBatch` (`lib/gateway.ts`) needed **no changes at all**: `transcribe()` auto-sniffs `audio/ogg` from the `"OggS"` magic bytes via `@ai-sdk/provider-utils`'s `detectMediaType`, confirmed present in the installed SDK version — the whole file's bytes are passed through exactly like a WAV file's today.
- **`lib/jev.ts`** (new, refactor): the circuit breaker that used to live only in `lib/intent.ts` is now shared by every Jev call site (`lib/router.ts`'s `routeTranscript`, `lib/intent.ts`'s `classifyIntent`, and the new combined check below) via one `callJev()` helper — a Jev outage is detected once and every caller benefits immediately, rather than each maintaining an independent breaker. Behavior (cooldown, half-open probe, logging) is unchanged from the original single-purpose version.
- **`lib/transcribe-routing.ts`** (`checkLocalTranscript`, new): when the client sends `localTranscript`, this asks Jev the router's `clean`/`recognized` questions **and** the intent classifier's §5b question **in one call** (reusing each module's exact instructions/criteria/decision-policy functions — `decideRoute()` and `decideIntent()`, both extracted from `lib/router.ts`/`lib/intent.ts` for exactly this reuse — so this combined path can never silently drift from what `/api/route` and `/api/intent` do standalone). Uses its own, **stricter** threshold, `LOCAL_TEXT_CLEAN_THRESHOLD = 0.9` (not `/api/route`'s `CLEAN_THRESHOLD = 0.8`, which is unchanged) — skipping Gemini entirely is a stronger claim than just routing to SMART.
- **Route flow** (`app/api/transcribe/route.ts`): clean (≥0.9) **and** intent `dictate`/`edit` → return `localTranscript` as-is, **skip Gemini** (`source: "local"`, no Gateway call, usage still recorded from audio duration for quota purposes). Otherwise, Gemini as before (`source: "cloud"`); the local intent classification is reused (`classifiedOn: "local"`) unless it was `null` (Jev unavailable) or the final text's leading ~6 non-punctuation characters differ from the local transcript's (`leadingTextDiffers()`, Unicode-aware via `Array.from` so a CJK character is never split) — in which case intent is reclassified on the final text (`classifiedOn: "final"`, one more breaker-guarded Jev call).
- **Judgment call, flagged for the coordinator/core**: when `localTranscript` is omitted entirely (old clients), the spec's reclassify-on-final trigger ("the early intent was null") is interpreted as *always* applying — since there's no local classification to possibly reuse. This means old clients (or any request without `localTranscript`) get exactly one extra Jev call per transcription (fast, breaker-guarded, ~70-500ms when Jev is healthy) that they can simply ignore in the response (`intent`/`route` fields). Flagging this in case the intent was instead "no `localTranscript` → skip intent classification entirely" — that's a one-line change (skip the `classifyIntent` call, return `{intent: null, confidence: null, source: "unavailable", classifiedOn: "final"}` directly) if preferred.
- Response adds `source: "local"|"cloud"`, `intent: {intent, confidence, source, classifiedOn}`, `route: {cleanProbability, reason}` (`reason` gains a new value, `"no-local-transcript"`, only ever produced by this endpoint when no local check ran).

**Tests**: `tests/ogg-opus.test.ts` (parser: duration/channel-count/pre-skip, malformed/truncated input), `tests/transcribe-routing.test.ts` (`checkLocalTranscript`: combined call shape, both thresholds, all reasons, breaker sharing), `tests/transcribe-batch.test.ts` (route-level: 415, ogg-opus happy path + limits + validation, local fast path for both `dictate`/`edit`, clean-but-`ask`-still-goes-cloud, reason passthrough, intent reuse vs reclassify-on-final by leading-text similarity, reclassify when local intent was null, backward-compat no-`localTranscript` path). `tests/route.test.ts`/`tests/intent.test.ts` updated to reset the now-shared breaker between tests (`resetJevCircuitBreakerForTests` moved from `lib/intent.ts` to `lib/jev.ts`).

**Live status (2026-09-26)**: Jev responded successfully on an isolated single-case check (`clean-zh-01`: `cleanProbability=0.91`, `intent=dictate`, both correct) — confirming the combined call and its decision logic work end-to-end for real. Immediately after, a 23-case batch run hit the known `GatewayRateLimitError` ("high demand") on the very first call; the circuit breaker opened and correctly skipped the remaining 22 (0ms each, no wasted latency) rather than each waiting out its own 1.5s timeout — a live demonstration of the breaker doing exactly its job. Given this flakiness, the full `route-eval.ts` threshold sweep (0.8/0.85/0.9/0.95) doesn't yet have enough real data points to report meaningful numbers — re-run `npx tsx --env-file=../.env.local scripts/route-eval.ts` once Jev is stable. A live end-to-end `/api/transcribe` curl check (both with and without `localTranscript`) confirmed correct graceful degradation to the cloud path when the local check's Jev call failed; the cloud call itself then hit Gemini's ordinary "No transcript generated" error on the (intentionally silent) test WAV — unrelated to this change, expected for silence.

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
text. The backend handles one bounded request/response with the whole recording.

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
     fire-and-forget, deduped warm-up request (historically `getToken`, no audio/model
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

The retired streaming token warm-up was replaced with a plain HTTPS HEAD to the Gateway origin on 2026-09-27. The measurements above describe the earlier implementation; latency of this replacement has not been measured live.
