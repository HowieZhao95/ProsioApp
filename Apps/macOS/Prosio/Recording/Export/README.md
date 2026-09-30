# Recording handoff boundary

`RecordingProjectExporter.export` creates a new package directory and returns its handoff file URL. Raw files are validated with AVFoundation, copied on a detached worker in bounded chunks, and published with a final no-overwrite move. Cancellation or a failed media read discards the private staging directory. `recording.json` preserves integer microsecond offsets and relative media paths. Editor URLs point at the final destination; moving a package may require relinking its bundled Media directory.

- Final Cut Pro: FCPXML 1.10, native video multicam angles, recovered / leading gaps and independent connected mic / system audio with roles. Rational durations come from media metadata; no assumed 30 fps timebase.
- Resolve / Premiere: FCP7 XML 5, independent aligned video tracks plus all audio channels. Stereo source channels have linked clip references. Frame positions use the chosen sequence rate, including NTSC rational rates. Native multicam conversion still needs editor integration and physical acceptance.
- Jianying: experimental plaintext draft and metadata, based on the pinned Apache-2.0 pyJianYingDraft schema. No Python runtime is used; no existing editor draft is changed. Platform templates originated from the Windows 5.9 schema and are not proof of current macOS compatibility. Files include the source license and attribution. Source: https://github.com/GuanYixuan/pyJianYingDraft/tree/6bb2d06a713f7b58e1375269daec835a03882086.

`RecordingVideoExporter.composition` assembles one selected video source and independent audio sources, preserving all timeline gaps. `exportMP4` trims non-destructively, mixes audio sources with balanced gain into a playable MP4, stages the output and refuses replacement of an existing file. Originals remain intact.

Validation: `RecordingExportTests` writes actual 29.97 H.264 MOV and mono / stereo 48 kHz CAF fixtures, parses all four handoffs, verifies offsets, gaps, independent media / stereo references, two-hour segmentation, path / symlink protection, collisions, cancellation and real MP4 duration. Isolated Swift 6 test package at `/tmp/prosio-export-test` exercises this code without launching Prosio or editors. Apple FCPXML 1.10 and archived FCP7 XML 5 DTDs can be obtained from the official documentation for schema validation.

Current editor application imports, relinking, native multicam behavior in Premiere / Resolve, and Jianying macOS compatibility remain **unverified**. XML / JSON validity and a passing synthetic test do not establish editor acceptance.

Primary format references:
- https://developer.apple.com/documentation/professional-video-applications/document-type-definition
- https://developer.apple.com/documentation/professional-video-applications/multicam-media
- https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/Elements/Elements.html
