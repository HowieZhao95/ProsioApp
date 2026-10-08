# Screenshot font preservation acceptance — 2026-10-03

The installed `/Applications/Prosio.app` was personally tested through its real ScreenCaptureKit selection and translation toolbar. A native TextEdit RTF fixture supplied known font families, weights, sizes and colors on a solid dark background. These are actual captured pixels and app exports, not mockups.

## Observed output

| Source text | Known source face | Source size in pixels | Final saved translation size in pixels |
| --- | --- | ---: | ---: |
| Screenshot translation test | Helvetica-Bold | 64 | 65.69 |
| Your changes have been saved. | Helvetica | 36 | 37.48 |
| Privacy and security | Helvetica-Bold | 36 | 37.54 |
| The meeting starts at 10:30 AM. | Menlo-Regular | 32 | 33.11 |
| Save screenshot | TimesNewRomanPS-ItalicMT | 40 | 39.81 |
| Small supporting text | Helvetica | 28 | 29.06 |

All six saved font names matched the source faces. The large bold heading, red bold subheading and body/small-text hierarchy remained visible after translation. The meeting time retained its Latin monospace digits. Chinese glyph fallback retained a serif appearance for the serif source; exact italic appearance is not guaranteed when the source font lacks the destination script.

Undo restored the English source in one step; redo restored the Chinese overlays. Copy and exit produced the actual `font-preservation-translated.png` (1207×356), with all six translations visible. The committed document was inspected and its six font names, fitted sizes, source masking rectangles and original source strings were retained in `font-preservation-document.json`. The user's clipboard was restored and its original data verified.

## Validation and performance boundary

- 142 capture tests / 19 suites passed, including 16 translation/typography tests. Log: `/tmp/prosio-translation-typography-capture-regression.log`.
- The separate immutable native Retina fixture, `font-preservation-source.png`, is used by the OCR/font regression. It matches all six source faces/weights, with estimated source sizes within 5.4% of the known sizes.
- Tests cover wrapping at the source size before shrinking, neighboring text constraints, dark background and colored ink, full glyph rendering, optional metadata backward compatibility, geometry transformations and source size hierarchy.
- Font comparison runs on the OCR worker and is cached with recognition. At most 96 small font templates are rasterized per selection; later regions use metric estimates. It adds no remote model call or pixel upload.
- Signed application build succeeded. Strict deep signature verification passed. Installed executable SHA-256 matches the validated build: `1da56d5f1dedb667c034d1a42699400c0043cc7bf31c8267f91da10e2dd51f03`.
- The installed app was returned to ordinary startup without `--capture-test` after acceptance.

Font preservation is best effort. Uncommon faces and destination scripts unsupported by the source face use nearby/system fallbacks. Insufficient space can require smaller text; gradients/photos still have approximate rectangular background replacement.
