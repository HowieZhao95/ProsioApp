# Daily notes native validation

Run `bash tools/notes-ui-validation/run.sh` from the repository root. Requires Xcode 26 and XcodeGen. It builds an isolated macOS app and runs the 18 storage, task-statistics and holiday-index tests without launching the full application or touching its note directory.

Open `/tmp/prosio-notes-ui-build/products/Build/Products/Debug/NotesValidation.app` for native interaction checks. Samples, recovery files and settings use a separate temporary directory and preference suite. The global shortcut is disabled at launch so the fixture does not compete with the real app. A selected shortcut can be registered through fixture settings; quitting unregisters it.

Manual checks: edit and confirm the dated file updates, open the date calendar and select yesterday, return to today, toggle pinning, open Settings using the app Settings command, hide/reopen and restart. Verify only Settings includes a folder picker. For an empty-day check select a past empty date and confirm no file is created until text is entered.

Override `PROSIO_NOTES_BUILD_DIR` to choose a fixture build location and `PROSIO_NOTES_VALIDATION_ROOT` when launching the app executable to choose a sample/recovery location.

Task checks: tick a task in the rich editor and verify today’s pending count updates immediately; the calendar shows completed/pending counts and the selected date’s task titles. Selecting a historical day leaves today’s header count unchanged. Counts persist across saves and restart.

For animation checks, launch the fixture executable with `--validate-animation` and a separate `PROSIO_NOTES_VALIDATION_ROOT`. It writes `animation-check.json` covering completed show/hide, reversal during fade, and canceling an asynchronous pending hide; then exits. It uses a separate animation preference suite.

Holiday integration is off by default. Settings has a system-holiday toggle and calendar-source selector after authorization. Do not accept a Calendar permission prompt during automated QA; real data access requires the user’s grant. Pure date-mapping tests cover multi-day, exclusive end, timezone, clipping and duplicate titles.

Chapter navigation checks run against the actual bundled editor through ego-browser. Regenerate the editor bundle first, then configure the absolute repository path and import the script:

```js
// Inside ego-browser nodejs:
globalThis.outlineCheckConfig = { repo: "/absolute/path/to/ProsioApp" };
await import("/absolute/path/to/ProsioApp/tools/notes-ui-validation/outline-check.mjs");
```

Optional `spaceId` resumes an existing validation TaskSpace. The script covers hover expansion/collapse, the hover bridge, heading hierarchy, click/scroll tracking, keyboard navigation, source/rich editing, original Markdown preservation, duplicate titles, code exclusion, unsupported Markdown, readonly navigation, and the minimum window in both themes. It simulates reduced motion for deterministic scroll checks and closes its TaskSpace on success. For native visual checks, open the fixture with a separate validation root and add headings to its sample note. Verify the rail stays unobtrusive, the panel fits the window, and Escape closes the directory before the note.
