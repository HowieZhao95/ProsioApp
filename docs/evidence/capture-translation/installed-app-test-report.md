# Installed app screenshot translation acceptance

Date: 2026-10-03. Installed app: `/Applications/Prosio.app`, signed Debug build.

The opt-in Debug argument `--capture-test` enters the real ScreenCaptureKit capture/editor flow. All selections, toolbar clicks, undo/redo, save dialog and pin actions below were performed with native computer-use UI controls. Normal launches keep screenshot window sharing disabled.

| Check | Observed result |
| --- | --- |
| Live capture and translation | Six English fixture lines became six Chinese overlays in place; 10:30 retained. |
| Undo | One toolbar click removed the entire translation and restored the frozen English pixels. |
| Redo | One toolbar click restored all six overlays. |
| JPEG save dialog | Saved a 1276×228 JPEG containing the Chinese text, inspected visually. |
| Copy and exit | Clipboard contained an 862×206 PNG with all six translations, inspected visually. Previous clipboard restored afterward. |
| Repeat translation/cache | Clicking translation again on the same selected source left backend request count unchanged at four. |
| Persistence | Restarted app and opened its latest screenshot history entry; all six overlays remained visible. |
| Pin | Clicked the actual toolbar pin action; native floating image displayed all translations; closed test pin afterward. |
| Return to normal operation | Restarted the installed application without the QA argument. |

Actual six-segment backend durations were 2293.2 ms and 1642.0 ms, including authentication and model translation. These measure backend processing, not total click-to-paint latency; UI observation occurred after completion. Earlier regression measurements cover OCR and cached layout separately.

Evidence: [saved JPEG](installed-app-translated.jpg), [copied PNG](installed-app-clipboard.png). These are app-produced exports, not synthetic render fixtures.

Limits: tested the English fixture on the built-in Retina display with a dark text-editor background. Multi-display capture, large text pages, every target language and single-Option shortcut delivery were not exercised in this UI run. The existing rectangular replacement uses approximate background sampling; it is not photographic inpainting. Unit regression covers cancellation, stale results, batching/concurrency, limits and redaction exclusion.
