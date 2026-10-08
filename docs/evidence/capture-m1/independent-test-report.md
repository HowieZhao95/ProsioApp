# Capture M0/M1 independent test report

Date: 2026-09-27. Reviewer: capture_tests. Status: automated checks passed; manual acceptance remains pending.

## Scope and isolation

- Upstream baseline: `7919eac9df9d9dec8427dbc0c10aecd32baf5530` at `/tmp/snip-review-20260927`.
- Runtime: macOS 26.3.1(a), Apple M1, 8 GB, one built-in Retina display (2560 × 1600 pixels).
- Existing app tests compile pure logic directly into a hostless bundle. They must remain hostless: launching an app with Prosio's bundle ID can replace the user's running app.
- Dedicated DerivedData: `/tmp/prosio-capture-test-dd-20260927`. No TCC changes, application launch, clipboard mutation, or real capture is part of automated tests.
- Storage tests must use fresh temporary roots and simulate failure without filling disk.

## Required automated cases

| Area | Independent checks |
| --- | --- |
| Coordinates | Primary, negative-x external screen, external screen above/below primary; AppKit bottom-left to capture top-left conversion; 1x, 2x and fractional point selections; noninteger scaling; clamping/rejection at display edges; zero/invalid bounds; cross-display selection never silently clips |
| Persistence | Pixel contents/dimensions survive fresh-store reopen; stable ID and timestamp; newest-first list; deletion removes only target; missing source and corrupt/version-incompatible metadata have explicit behavior |
| Failure | Invalid root / write failure produces no published asset; failed metadata commit does not leave successful-looking index; decode failure preserves diagnosable data; filenames cannot escape storage root |
| State | Busy flow suppresses duplicate invocation; cancel at selection/capture restores idle and cannot publish later completion; failures reset flow; stale callbacks cannot overwrite a newer request |
| Regression | Existing hostless AX coordinate and voice hotkey tests; applicable ProsioCore voice tests |

## Manual acceptance still required

Automated geometry/store tests and builds do not prove ScreenCaptureKit permissions, actual image orientation, window shadows, own-overlay exclusion, capture permission denial/revocation, overlay keyboard/focus cleanup, clipboard/save panel, or voice event handling in the running app. These require authorized real-app interaction. External display/retina topology and deployment on macOS 26.0 are not available in this environment.

## Results

- Baseline hostless app tests: **19 tests / 3 suites passed**. Result bundle `/tmp/prosio-capture-baseline-20260927.xcresult`, log `/tmp/prosio-capture-baseline-20260927.log`.
- Existing voice/core regression: **32 tests / 5 suites passed**, filtered DictationControllerTests, DictationControllerDebugRecordingTests, LiveComposeTests, AppSettingsTests. Log `/tmp/prosio-capture-core-20260927.log`; separate Swift package scratch directory.
- Capture tests: geometry (7), request planning (5), hotkey ownership (3), persistence/failure (11). **Final combined hostless run: 45 tests / 7 suites passed** (26 capture tests plus 19 existing tests), including deterministic mid-write cancellation and filesystem manifest failure. Result bundle `/tmp/prosio-capture-tests-accepted-20260927.xcresult`; log `/tmp/prosio-capture-tests-accepted-20260927.log`.

## Review findings and resolutions

1. `gscScaledRect` initially did not standardize negative-width/height input before choosing its corners. Corrected; the reverse-drag test passes.
2. `save` initially used a detached task without propagating cancellation. Corrected with initial cancellation check, cancellation propagation to the writer, and checks before manifest/commit. Already-cancelled tests pass. The deterministic after-PNG checkpoint test checks cancellation during writing; once committed, the asset remains published and discoverable.
3. Store reload initially validated only PNG existence, allowing a corrupt image to be listed. Corrected to validate PNG dimensions/properties; damaged PNG and truncated-header tests pass and retain diagnostic files.
4. Empty selection topology, first responder, hotkey handler ownership, and focus restoration were reviewed by root and corrected by the implementer. The selection UI now explicitly says it is limited to its display. Real focus/keyboard behavior remains unverified.

The store uses complete-directory manifests as its index, so there is no separately committed global index. Manifest encoding failure is still meaningful: a valid PNG plus nonfinite source geometry causes the manifest encoder to fail after PNG creation; tests require no published asset and no pending directory after failure.


## Coverage boundaries

The hotkey tests prove routing predicates and the deferred-effect suspension gate. Actual production call sites were reviewed, but those tests do not drive Carbon event delivery or prove the whole UI busy/cancel lifecycle. Store cancellation tests cover pre-save and deterministic after-PNG/pre-manifest cancellation, not every timing around the final atomic rename. The coordinator does not expose a hostless UI injection layer, so no automated claim is made for modal-picker cancellation, stale UI callbacks, overlay behavior, permission prompts, or focus restoration. No app instances were started or stopped.
