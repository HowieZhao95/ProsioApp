# Capture M2 independent test report

Date: 2026-09-28. Status: automated and synthetic native checks passed; real system-capture acceptance remains pending.

## Final results

- Main project, hostless `ProsioTests`: **88 tests / 16 suites passed** — 43 new M2 tests and 45 existing M1/voice-coordinate/hotkey tests. Result bundle: `/tmp/prosio-m2-main-accepted-20260928.xcresult`. Archived log: `hostless-tests-final.log`.
- Applicable voice/Core regression: **32 tests / 5 suites passed**. Archived log: `voice-core-regression.log`. ProsioKit voice production sources were unchanged afterward, so these were not repeated.
- Preliminary isolated M2-only checks found two production defects (below); after fixes, 30 pure model/geometry/detector tests passed before native tests were added.
- Latest relevant production-source modification observed before final run: `Capture/Integration/CaptureCoordinator.swift`, **2026-09-28 00:20:47 +08:00**. Final test completed at approximately **00:22:57 +08:00**. Synthetic native PNGs refreshed at **00:22:55–56 +08:00**.

Tests use independent DerivedData (`/tmp/prosio-m2-main-test-dd-20260928`) and isolated temporary asset roots. The preliminary XcodeGen harness exists only under `/tmp/prosio-m2-logic-harness-20260928`; it did not modify the repository project. No user app was launched or terminated, no TCC settings changed, and no system-screen or clipboard contents were accessed. Native tests instantiate the production canvas/toolbar/session inside hidden test-owned windows and never call `session.begin()` or order windows onto the user's desktop.

## Verified coverage

| Area | Evidence |
| --- | --- |
| Source coordinates and editing | Moving/resizing crop preserves source-pixel annotation geometry. Undo/redo covers update/delete, selection-only state, and abandoned redo branches. All annotation geometry kinds translate consistently. |
| Actual rendering | An asymmetric synthetic gradient checks crop orientation, corners, actual pixel dimensions, and selected UI state exclusion. Solid redaction stays anchored after crop changes. Blur/mosaic process already composited annotation layers and leave outside pixels intact. |
| Restricted editable persistence | V2 stores only selected source pixels; off-crop annotations are omitted, related geometry translates to crop origin, and transient selected IDs disappear. Fresh-store rendering equals the original flattened output. Local editable source and flattened export are checked separately. V1 PNGs open as whole-image documents. |
| Failure/cancellation/history | Real document-manifest filesystem write failure and deterministic cancellation after PNG creation leave earlier history intact and clean only their own pending directory. External-output failure rolls back its newly created asset; success retains the same asset passed to external output. |
| Damaged documents | Invalid JSON, source-image dimension mismatch, and inconsistent document-crop dimensions produce recovery warnings and preserve diagnostic files instead of silently reopening another image. |
| Toolbar/handles/snap | All screen corners, tiny/full-screen selections, expanded properties, compact-layout requests, previous-side retention, all eight handle bounds/minimum sizes, entry/release hysteresis, stale snapshot rejection, confident/finite candidate filtering, and conservative front-window occlusion filtering. |
| Native event chains | Actual `mouseDown`/`mouseDragged`/`mouseUp` on production canvas confirm initial selection snapping, immediate source-pixel crop, fitted history-window reselect mapping, and all eight handles winning over an active redaction tool. |
| Native text/output lifecycle | Return inserts a line; Cmd-Return commits text without screenshot output. History re-edit preserves stored style and scales the native font to image fit. Duplicate outputs and crop edits while busy are rejected; save cancellation/failure preserves edits for retry; late success cannot finish a force-cancelled session twice. |
| Key routing | Text owns Return/Cmd-C. Cmd-Return commits only outside marked composition. Marked-text Esc remains with the input method. Output-in-progress dispatches no additional action. |
| Controlled panel detection | A single synthetic bordered panel produces the expected snapshot-bound candidate and offset coordinates. Cancellation and normalized Vision coordinate boundaries are also checked. This does not establish arbitrary webpage/div recognition. |

## Independent review findings

1. **Fixed:** Crops touching only thick rectangle stroke initially dropped that annotation during restricted persistence. A stroke-only crop now retains the annotation and identical reopened pixels.
2. **Fixed:** Source PNG dimensions and editable crop dimensions initially could disagree with the flattened asset without rejection. Deterministic corruption fixtures now produce warnings and no published asset.
3. Root's production-path review also led to first-selection snap, history-fit mapping, text-layout/style, narrow toolbar, output rollback, and marked-text Esc changes; the applicable behaviors are covered above. Optional detector failure fallback, actual screen permissions, and real system focus remain outside this harness.

The first native text tests queried only direct canvas children. The production text editor was moved inside a clipping container to preserve layout width, so the harness was corrected to find the actual descendant text view. That was a test traversal correction, not a text-input defect.

## Synthetic native visual evidence

All three files below show the **production native UI drawn over synthetic gradient pixels**, not a captured desktop:

- `synthetic-native/synthetic-native-light.png`
- `synthetic-native/synthetic-native-dark.png`
- `synthetic-native/synthetic-native-narrow.png`

Final images were visually inspected: toolbar and its controls remain within the captured canvas, the narrow layout folds tools/properties, and the tightened toolbar leaves less unused space. Light/dark comparisons sample three selection-interior points away from toolbar/borders: the two rendered canvases match exactly, and source pixels match within a six-channel-value tolerance for native image scaling/color conversion. Snapshot and original pixel data remain unchanged.

## Remaining real-app acceptance

These results do not prove ScreenCaptureKit's permission/grant/deny/revoke paths, own-overlay exclusion in real capture, actual clipboard paste or save panels, multi-monitor runtime/Spaces/focus restoration, real Chinese IME composition, arbitrary webpage panel detection, or abnormal-process draft recovery. No claim is made that a successful build or synthetic canvas test is physical screen-capture acceptance. Final application signing/build verification is reported separately by root/implementation.
