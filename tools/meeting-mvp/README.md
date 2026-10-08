# Independent meeting transcription MVP

This executable is a technology probe. It does not import ProsioKit, change the running Prosio app, use the short dictation backend, or meter product quotas. It tests these pieces separately:

1. Microphone capture (`AVAudioEngine`) and system audio capture (`ScreenCaptureKit`) into local files.
2. Apple `SpeechTranscriber` progressive updates while replaying an audio file at real-time speed.
3. Apple final-only, time-indexed transcription of a recorded file.
4. FluidAudio offline diarization and conservative timestamp overlap attribution.
5. Optional Soniox `stt-async-v5` file transcription with diarization. This is explicitly invoked and billed by Soniox; a local report survives a cloud error.

## Build

Requires macOS 26, Xcode 26, and Swift 6.2 or newer. The bootstrap script pins a known compiling FluidAudio commit because its `v0.9.1` tag failed Swift 6.3 concurrency checks on this host. It fetches that single commit into an ignored local vendor directory, avoiding a full-history SwiftPM fetch.

```sh
cd tools/meeting-mvp
sh bootstrap.sh
swift build -c release
```

FluidAudio normally downloads its model assets on first run. If its URLSession download fails TLS validation while `curl` succeeds, run `python3 prepare_diarizer_models.py` once. The script uses normal TLS validation and checks each file's size against the pinned model revision. Apple may need to reserve or install its speech assets on first run.

## Capture and analyze

```sh
.build/release/MeetingMVP record-mic --seconds 30 --output /tmp/meeting-mic.caf
.build/release/MeetingMVP record-system --seconds 30 --output /tmp/meeting-system.m4a
.build/release/MeetingMVP replay-live --input /tmp/meeting-system.m4a --locale en-US
.build/release/MeetingMVP analyze --input /tmp/meeting-system.m4a --locale en-US --output /tmp/meeting-report.json
```

`record-system` captures audio attributed to the selected display. Start playback in a visible app while recording. It does not yet mix microphone and system tracks or save a unified meeting session. The `replay-live` command prints progressive revisions; a UI should replace the current provisional span instead of appending every update.

The report contains final Apple utterances with tentative speaker labels, FluidAudio speaker spans, processing times, and optional Soniox tokens. A missing speaker means the overlap was too weak or ambiguous to label safely.

## Optional Soniox test

For this local probe only, load `SONIOX_API_KEY` into the process environment from your local secret store, then explicitly pass `--soniox`. Do not put the key in this repository or a shell command saved in history.

```sh
.build/release/MeetingMVP analyze \
  --input /tmp/meeting-system.m4a --locale en-US \
  --output /tmp/meeting-cloud-report.json --soniox
```

The audio file is sent directly to Soniox, then the remote transcription and file are deleted after the result is received or the job fails. This direct-key path is **only for isolated local validation**. The product implementation must use a server-held key, private object storage, atomic quota reservation, and resumable jobs as described in [the implementation plan](../../docs/MEETING-TRANSCRIPTION-PLAN.md).

## Limits of this MVP

- The two capture commands are independent; no two-track session, echo removal, device-switch handling, or crash recovery yet.
- Apple live captions are validated by real-time replay, not directly from a live microphone or video-call app.
- Speaker labels are unknown IDs within one recording. They are not identity recognition.
- No UI, billing, background job recovery, or long-file cloud upload path is included. These belong to the product implementation after technology validation.
- This probe uses local English and AMI meeting samples, plus synthetic Chinese TTS. Apple's `zh-CN` result was good for pure Chinese and poor for embedded English terms in that synthetic sample. Real bilingual speech, actual Zoom/Teams calls, and Soniox need separate authorized inputs.
