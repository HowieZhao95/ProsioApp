# Synthetic recording soak test

This runner uses the production segmented H.264/AAC writer with three synthetic video sources and two independent PCM audio sources. It never enumerates or captures a screen, camera or microphone, and cannot request capture permissions.

Run a bounded smoke first:

```sh
tools/recording-stress/run.sh --duration 10 --segment 5 --output /tmp/prosio-recording-stress-smoke
```

For the two-hour encoder soak, choose an empty output directory with sufficient free disk space:

```sh
tools/recording-stress/run.sh --duration 7200 --width 1920 --height 1080 --fps 30 --segment 60 --output /path/to/empty/stress-output
```

`progress.json` updates every five seconds. `report.json` contains finalized playable segments, offsets, media bytes, resident-memory samples, actual elapsed time, maximum scheduling lag, queue peak, writer admission/encoder drops, fixture-pool skipped frames, warnings and errors. The pixel pool is bounded, images remain immutable after publication, and the high-entropy static background plus moving rows exercise actual video encoding. A fixture skip is distinct from a writer drop.

The temporary build is a command-line target in `/tmp`; it does not launch Prosio or modify the application project. This verifies encoder/writer stability under synthetic wall-paced load. Camera transport, Continuity Camera, device disconnects, ScreenCaptureKit timestamps, and real two-hour audiovisual drift require separate device acceptance.
