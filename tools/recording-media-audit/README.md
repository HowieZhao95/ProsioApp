# Recording media audit

This read-only macOS CLI checks the completed media files named by a stress-run `progress.json` / `report.json` or a production `recording.json` / `manifest.json`. It reads actual AVFoundation asset playability and track metadata, checks manifest in/out points and format metadata, then reports each source's timeline gaps and overlaps. JSON is written to stdout; media and input manifests are never changed.

```sh
# Default media root is the input JSON's parent directory.
tools/recording-media-audit/run.sh \
  /tmp/prosio-recording-stress-smoke/progress.json \
  /tmp/prosio-recording-stress-smoke

# Explicitly audit a completed production recording manifest.
tools/recording-media-audit/run.sh \
  "$HOME/Library/Application Support/Prosio/Recordings/<session>/manifest.json" \
  "$HOME/Library/Application Support/Prosio/Recordings/<session>"
```

The tool accepts `segments` arrays in both stress reports and production manifests. Progress snapshots are marked incomplete based on their `completed` flag and are explicitly reported as partial; only segment entries already published in that snapshot are opened. Paths must be relative, traversal-free, and resolve inside the media root after symlinks. Empty, missing, unreadable, or corrupt media is reported per segment.

The declared media interval is `[mediaStartMicroseconds, mediaStartMicroseconds + durationMicroseconds]`. It is checked against the AVAsset duration and every present audio/video track time range. The JSON includes the tolerance applied to each track. Video range comparisons allow at most one encoded video frame, using the track's nominal frame rate (or 30 fps if absent). AAC audio allows at most two AAC-LC access units, calculated as `2 × 1024 / sampleRate` seconds (or 48 kHz if metadata is absent); other audio codecs allow one sample period only. These are codec-boundary allowances, not general sync tolerances. Declared dimensions, sample rate, and channel count are compared with actual track format descriptions when both sides provide a value; known source kinds also require a corresponding video/audio track. `isPlayable` is AVFoundation's container/codec playability declaration plus metadata inspection; it does not decode every frame, so damaged payloads or bad frames still need playback/decode acceptance.

Timeline continuity is checked independently for each source. A gap or overlap is reported when adjacent manifest ranges differ by more than 1 ms. Gaps are informational because a disconnected source can legitimately leave a recording gap; overlaps and invalid ranges fail the audit. An input with no published completed segments is explicitly marked `noCompletedMedia` and exits as not audited successfully, rather than treating 0/0 as a pass. Cross-source timeline spans are included for inspection, but synthetic timestamps cannot prove camera lip-sync or real-device two-hour drift. This tool does not enumerate devices, capture media, request TCC permissions, launch Prosio, repair files, or delete/overwrite originals.


## Full decode while a synthetic stress run continues

`live_decode.py` complements the AVFoundation metadata audit by decoding every frame and streaming every PCM sample from the finalized files. It requires Python 3 and ffmpeg. It never starts capture or changes the source files.

```sh
python3 tools/recording-media-audit/live_decode.py \
  /tmp/prosio-recording-soak/media-run \
  /tmp/prosio-recording-soak/full-decode.json \
  --watch --writer-pid 12345 \
  --writer-executable /tmp/your-build/ProsioRecordingStress
```

Replace the PID and executable with the currently running stress writer. Without `--watch`, the command audits one published snapshot. The output must be separate from source media and the writer's reports. Successful snapshot decoding is explicitly partial; final success requires a nonempty completed `report.json`, complete decode coverage, and no writer failures. Writer warnings and drop counts remain visible separately, so decode success does not imply zero loss or physical-device stability.

The watch caches results only while media path, segment metadata, size and modification time are unchanged. On writer exit it checks again for a newly finalized report before reporting an incomplete run. Decode errors, error-level ffmpeg diagnostics and per-file timeouts terminate the watch with a nonzero result. Video uses timestamp passthrough so missing input frames are not replaced for the frame count; PCM counts may include AAC padding and are not valid-content sample counts. Decode work consumes CPU and disk bandwidth and must be recorded as background load when interpreting encoder performance.

```sh
cd tools/recording-media-audit
python3 -B -m unittest -v test_live_decode.py
```
