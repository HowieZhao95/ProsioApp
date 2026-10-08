# Meeting transcription integration

## Runtime path

1. The meeting pane in the Prosio menu bar starts a dedicated `MeetingRecorder`. The microphone is written to `microphone.caf`; ScreenCaptureKit writes system sound to `system.m4a` when screen recording permission is granted. Losing system capture leaves the microphone track intact.
2. Two Apple `SpeechTranscriber` progressive sessions receive copied PCM frames and display provisional captions separately by source. They do not become the saved transcript.
3. Stop closes the audio writers first. `MeetingProcessor` then makes a final Apple pass over both files and runs FluidAudio diarization. Each utterance keeps its source track and source-local speaker ID. Ambiguous speaker overlaps remain unlabeled.
4. `MeetingStore` writes a manifest atomically under `~/Library/Application Support/Prosio/Meetings/<UUID>/`. It retains the raw tracks, Apple/FluidAudio draft, and a distinct optional Soniox version. The library can reopen interrupted sessions and retry processing from saved files.
5. When the signed-in user opts into cloud enhancement, `MeetingCloudAudio` exports one mixed M4A. The backend reserves quota, issues signed multipart S3 uploads, submits one Soniox `stt-async-v5` task with diarization, and returns tokens after polling. A failed or exhausted cloud route leaves the local draft available. Provider credentials are server-only.

## Build and configuration

Run `scripts/bootstrap-fluidaudio.sh` once before generating the Xcode project. It fetches FluidAudio at a verified pinned commit into an ignored local checkout. Then run `xcodegen generate` and build the `Prosio` scheme. FluidAudio's speaker models download on first use into its user cache.

Cloud enhancement requires an existing Postgres schema for `users` and `usage_events`, the additional migration in `server/sql/meeting_jobs.sql`, a private S3-compatible bucket, `SONIOX_API_KEY`, and `CRON_SECRET`. Set the variables documented in `server/.env.example`. `server/vercel.json` schedules expired job cleanup daily. Never put the Soniox key in the Mac bundle.

## Verification completed in this workspace

- `swift build --package-path Packages/ProsioKit --target ProsioMeeting`
- Prosio Xcode Debug build
- `MeetingStoreTests`: interrupted manifest and recorded audio remain discoverable
- `MeetingCloudAudioTests`: two staggered tracks export to one nonempty M4A
- Server TypeScript typecheck and 378 server tests, including unauthenticated and unconfigured meeting requests
- The independent `tools/meeting-mvp/VALIDATION.md` records microphone/system capture, progressive Apple captions, final Apple transcription, FluidAudio diarization, and a 17.5-minute public meeting benchmark.

## Validation still required before shipping

This workspace has no Soniox key, S3 bucket, or Postgres URL; the actual provider call, multipart upload, atomic reservation under database concurrency, scheduled cleanup, and cloud result playback have not run against services. A real meeting app and a two-hour meeting have not been tested in the integrated Prosio UI. On this host FluidAudio model downloads through URLSession previously failed TLS validation; `tools/meeting-mvp/prepare_diarizer_models.py` prepared the model cache through normal curl certificate validation for the MVP. Verify first-use downloads on clean devices. Apple zh-CN recognition can mishear embedded English technical terms; Soniox is the opt-in enhanced version for this case. For recordings longer than 45 minutes, the current local processor keeps the Apple text but skips FluidAudio speaker labeling to bound memory until chunked, speaker-consistent diarization is validated. Sleep/wake, device changes, disk-full behavior, and acoustic echo across the two tracks need the acceptance run in `docs/MEETING-TRANSCRIPTION-PLAN.md`.
