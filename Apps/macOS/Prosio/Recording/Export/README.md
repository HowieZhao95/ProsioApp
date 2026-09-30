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

## Explicit app handoff and native interchange follow-up

`RecordingEditorHandoff.availability(for:)` reports installed application/version and whether an automatic open request can be offered. `open(exportedFile:editor:application:allowExperimentalMulticam:)` targets that installed bundle through NSWorkspace instead of a default XML handler. Discovery and opening are injectable for headless tests. The receipt records a request only and always reports `importVerified == false`; editor rejection or import dialogs still require acceptance. Jianying is version-gated: no current macOS version has yet been verified, so its JSON is not automatically opened or written into live draft folders.

Premiere exports now include `Multicam.premiere.experimental.xml`. This uses documented Apple XMEML `multiclip`, `angle`, `clip`, and nested `clipitem/sequence` nodes to retain recovered / segmented video sources as angles with separate audio tracks. It is intentionally an auxiliary candidate: Adobe's historical CS6 documentation supports uncollapsed multiclips with at most four inputs; **current Premiere and nested segmented angles are not validated**. Opening it requires an explicit experimental choice. Default `Timeline.xml` remains independent aligned tracks. Resolve also receives `Multicam.fcpxml` retaining the native angle definitions, with no claim that it automatically becomes a Resolve multicam clip.

Research evidence, checked 2026-09-30:
- Apple documented XMEML multiclip and nested sequence structure: https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/Basics/Basics.html and https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/FinalCutPro_XML/Elements/Elements.html.
- Adobe historical CS6 reference states that uncollapsed multiclips with <= 4 inputs become multi-camera sequences: https://helpx.adobe.com/pdf/cs6/premiere_pro_reference.pdf. This is historical evidence, not acceptance for a current editor.
- Current Adobe FCPXML migration instructions require conversion: https://helpx.adobe.com/premiere/desktop/organize-media/import-files/migrate-from-final-cut-pro-x.html.
- **XtoCC's own current help explicitly says multicams are flattened/collapsed to active angles**: https://www.intelligentassistance.com/xtocc-help/. Therefore installing or invoking XtoCC is not a demonstrated native-multicam preservation route.
- Blackmagic's official Resolve 11 manual describes imported FCPX multicams as compound clips: https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_11_Reference_Manual.pdf (page 375). The Resolve 17 official new-features guide documents converting a compound clip or timeline to multicam through a Media Pool command: https://documents.blackmagicdesign.com/SupportNotes/DaVinci_Resolve_17_New_Features_Guide.pdf. No verified one-request native import API was found in these primary sources.

`RecordingEditorHandoffTests` covers injected targeted opens, bundle discovery, missing or wrong applications, file-size and XML-root guards, failed launches, Jianying/current-version gating, and experimental native multicam structure with recovered offsets and stereo audio. It launches no user apps. Both launch delivery and four-editor physical import acceptance remain distinct gates.
