# Meeting MVP validation — 2026-09-28

Host: Apple Silicon Mac, macOS 26.3.1, Xcode 26.6, Swift 6.3.3. The working FluidAudio checkout was commit `20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14`, now pinned by `bootstrap.sh`.

| Check | Result | Evidence and limit |
|---|---|---|
| Swift release build | Passed | Built against a local checkout of the exact pinned FluidAudio commit. A shallow fetch of that commit took about 11 seconds. `v0.9.1` failed in FluidAudio's own Swift 6.3 concurrency code. |
| Microphone capture | Passed | Recorded a 2-second CAF file with `AVAudioEngine`. No spoken content, so transcription quality was not assessed. |
| System audio capture | Passed for a visible player | ScreenCaptureKit recorded 18.8 seconds of system audio from Terminal playing an AIFF file, with non-silent content. Apple recognized the main sentence. Background `say` synthesis was not consistently captured; a video-call app has not been tested. |
| Apple live behavior | Passed on paced file replay | 15-second two-voice sample yielded 62 progressive updates; first update at 1.07 seconds; final update after audio end. The executable replays a file at real speed; it does not yet wire live capture to the transcriber. |
| Apple final transcription | Passed on files | Uses final-only time-indexed preset. Progressive output was found to include long tentative ranges and must not be appended to the final document. |
| FluidAudio diarization | Passed on fixtures | Two-voice synthetic sample: two speaker spans, S1 then S2 at the expected turn. |
| Real meeting file | Passed technically | Public AMI `ES2004a.Mix-Headset` recording, 17.5 minutes: Apple 771 final segments; FluidAudio 94 spans, four speaker IDs; conservative alignment assigned 696 segments and left 75 unknown. Total processing 22.3 seconds after models cached. A separate `/usr/bin/time -l` run observed 358 MB maximum resident set size. No WER or diarization error rate was computed against annotations. |
| Cloud fallback without key | Passed | `--soniox` with no `SONIOX_API_KEY` preserved the local JSON report and recorded the missing-key reason. |
| Chinese local STT | Mixed | A synthetic pure-Chinese sentence was transcribed nearly exactly. In a synthetic `zh-CN` sentence containing “onboarding flow” and “conversion rate,” Apple distorted the English terms substantially. TTS voice pronunciation is a confounder; real bilingual speakers need testing. |
| Soniox Async live call | Pending | No Soniox API key was present in the workspace or process environment. No audio was sent to Soniox and no billing occurred. |
| Real bilingual speakers and call audio | Pending | Requires representative authorized audio and Mac capture in the actual call app. |
| Multi-hour reliability | Pending | This probe processed a 17.5-minute file. It has not recorded or processed a two-hour meeting. |

### Model provisioning observation

FluidAudio's automatic URLSession download failed certificate validation on this host. The same pinned model files downloaded successfully with `curl` using normal TLS validation and exact expected sizes, then FluidAudio loaded and ran them. `prepare_diarizer_models.py` reproduces that preparation if needed. This is a deployment/setup risk to resolve before product integration; disabling TLS validation is not a solution.

### Public sample source

The real meeting check used the [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) file [`ES2004a.Mix-Headset.rm`](https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/). It was converted locally to 16 kHz mono WAV for this probe; the sample and outputs remain in `/tmp`, outside the repository.
