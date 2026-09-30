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
