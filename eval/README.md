# SMART-mode evaluation harness

Decides whether Gemini SMART transcription is good enough for Chinese/English
code-switching dictation, by sending recorded test cases through the same
path the macOS client uses for final text, and scoring the output against a
hand-written "ideal" transcript.

## Files

- `cases.json` — 30 test cases. Each has:
  - `id` — stable identifier, also the audio filename stem.
  - `category` — `filler | self-correction | list | code-switch | names-jargon | punctuation | long-form`.
  - `language` — `zh | en | mixed`.
  - `script` — **what the tester should say**, including natural
    disfluencies (嗯/那个/um, restarts, self-corrections) — read this out loud
    when recording, don't "clean it up" while speaking.
  - `expected` — the ideal clean SMART-mode output.
  - `vocabulary` — personal-dictionary terms relevant to the case (names,
    jargon), fed to the model as vocabulary bias.
- `audio/<id>.wav` — your recordings (gitignored — not checked in). **16kHz**
  mono 16-bit PCM WAV, one file per case — this is the only rate Gemini
  accepts for batch transcription.
- `results/<timestamp>.json` / `.md` — output of a harness run (gitignored).

## Recording audio

Requires **ffmpeg**. Check what's on this machine:

```bash
ffmpeg -version   # this environment has ffmpeg 8.0.1 installed — adjust below if yours differs
```

Record straight to the right format on macOS (list input devices first,
since ":0" below is a device index, not a guarantee):

```bash
ffmpeg -f avfoundation -list_devices true -i ""        # find your mic's index, e.g. ":0"
ffmpeg -f avfoundation -i ":0" -ar 16000 -ac 1 -acodec pcm_s16le eval/audio/<id>.wav
```

Or record with any app/phone and convert afterwards:

```bash
ffmpeg -i input.m4a -ar 16000 -ac 1 -f wav -acodec pcm_s16le eval/audio/<id>.wav
```

Read the case's `script` field naturally, including the disfluencies — the
whole point is testing whether SMART mode cleans them up correctly. Record
all 30 (`eval/audio/mixed-01.wav` ... `en-08.wav`) for full coverage, or just
the ones you're iterating on.

## Running

From `server/`:

```bash
npm run typecheck && npm test          # sanity-check the harness itself first (no API calls)
npx tsx scripts/smart-eval.ts --dry-run              # validate cases.json + which audio files exist/parse
npx tsx scripts/smart-eval.ts                        # run every case that has audio, batch transport, SMART mode (P0 default)
npx tsx scripts/smart-eval.ts --case zh-03            # just one case
npx tsx scripts/smart-eval.ts --mode verbatim         # compare against verbatim mode
npx tsx scripts/smart-eval.ts --tts                   # synthesize placeholder audio for missing cases (see caveat below)
```

Requires `AI_GATEWAY_API_KEY` (see `server/.env.example`) to actually call
the Gateway; without it every case reports a clear "no Gateway key" error
and the script still exits cleanly. The `--tts` flag synthesizes speech via
the Gateway's TTS surface as a **smoke test only** — synthesized audio has
none of the natural disfluencies/code-switching prosody the cases are
designed to exercise, so don't use `--tts` results to judge SMART-mode
quality, only to check the wiring works end to end.

## Reading results

Each run writes `eval/results/<timestamp>.json` (full detail per case:
final text, CER, timing, heuristic results) and `<timestamp>.md` (a summary
table, also printed to stdout). Per case:

- **CER** — character error rate of the model's final text vs. `expected`,
  after normalising punctuation/whitespace/case (0 = perfect match).
- **latency** (batch transport) — wall-clock time of the whole
  `transcribe()` call, i.e. what a client would see from request to response.
- **heuristics** — category-specific pass/fail checks (e.g. "no filler
  words leaked into the final text", "numbered list formatting present",
  "every personal-dictionary vocabulary term appears verbatim") — see
  `server/lib/eval/heuristics.ts`.

There's also a mean-CER-by-category breakdown at the bottom of the markdown
summary, which is the quickest way to see whether SMART mode is
systematically weaker on, say, code-switching vs. plain Chinese.
