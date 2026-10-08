# Installed application / real desktop test

Date: 2026-09-28. Status: installed and running; live capture checks in progress.

- User requested installation and testing.
- Copied the accepted signed build to `/Applications/Prosio.app`; no existing app existed at that destination.
- Strict/deep code-sign validation passed before and after installation.
- Quit the old process through its normal Prosio → Quit menu. No forced termination.
- Launched `/Applications/Prosio.app`; process path verified (PID 90039 at the time of inspection).
- Prepared a separate TextEdit document containing only test text, without modifying the previously open user document.
- The native automation interface can inspect windowed applications, but connecting to the menu-only installed app currently times out. The user was asked to expand Prosio’s menu-bar menu so the live test can continue. Shortcut delivery via the automation interface has not yet been established.
- No screen-recording permission setting has been changed. Real capture, clipboard, save-panel and focus results are not yet claimed.

Previous build remains at `build/dd-architect/Build/Products/Debug/Prosio.app` for rollback. Accepted new build also remains at `build/capture-m2/Prosio.app`.

## Single-entry menu update

User requested one simple screenshot entry. The menu now has one Screenshot button and a Screenshot shortcut label. The signed incremental build passed (`/tmp/prosio-capture-m2-menu-simplified.log`), and the installed bundle was replaced with this verified build. The previous installed bundle is preserved at `build/capture-m2-before-menu-update/Prosio.app`. The currently running process was not terminated; it must quit and relaunch to load this change. Real UI acceptance remains pending due to the menu-only automation connection limitation.

## Live process switched to single-entry build

The user screenshot still showed the old menu. OS executable mapping confirmed PID 90587 was using the preserved pre-update executable despite its original /Applications command path. After control-flow logs showed dictation cancelled, that exact old process was terminated with SIGTERM (no force kill), and the installed app relaunched through the native app tool. The new process executable mapping resolves to `/Applications/Prosio.app/Contents/MacOS/Prosio`; one running installed instance was confirmed, and this binary has no Area/Window/Choose Display menu strings. Menu-only AX inspection still times out, so no visual acceptance is claimed.
