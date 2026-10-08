# Agent monitor validation

This is a hostless test project. It never launches the real Prosio app, installs hooks, starts an Agent, or changes Codex configuration.

From the repository root:

```sh
xcodegen generate --spec tools/agent-monitor-validation/project.yml
xcodebuild -project tools/agent-monitor-validation/AgentMonitorValidation.xcodeproj \
  -scheme AgentMonitorValidation -destination 'platform=macOS' \
  -derivedDataPath /tmp/prosio-agent-monitor-tests CODE_SIGNING_ALLOWED=NO test
```

The Unix transport tests use `/usr/bin/python3` from Xcode command-line tools to serve a fixture on their own temporary socket. No external service is involved.

Stage 2 / 3 adds separate control, desktop IPC, structured-question and task-bound voice tests. Read-only transport tests still assert their original read-only allowlist; control fixtures use separate connections and temporary sockets.

The `AgentAcceptancePreview` scheme builds an isolated app with the production Agent components. `--interactive` uses synthetic tasks and synthetic transcription. `--live-interactive` connects to existing local tasks and can answer structured questions, supplement a running task or interrupt a selected live task; use only with explicit authorization for that named task. Desktop supplements target the selected task's currently executing turn and verify the actual turn, command ID and full input record. A changed turn is reported separately. Answers and interruption retain their original request/turn constraints. Its microphone path uses the local audio/transcription libraries and requires normal OS permission. It does not launch a replacement Agent or change Codex configuration. See `docs/evidence/agent-interaction/acceptance.md` for real versus synthetic evidence.

After building `AgentAcceptancePreview`, its executable can render the question view with an output PNG path; add `--supplement` for the running-task view and `--dark` for dark appearance. All offscreen images use synthetic data. The final reviewed images are in `docs/evidence/agent-interaction/`.

Build the isolated UI / read-only diagnostic:

```sh
swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  Apps/macOS/Prosio/Agents/Domain/*.swift \
  Apps/macOS/Prosio/Agents/Platform/*.swift \
  Apps/macOS/Prosio/Agents/UI/*.swift \
  Apps/macOS/Prosio/UI/MenuBar/MenuBarShell.swift \
  tools/agent-monitor-validation/Preview.swift -o /tmp/prosio-agent-monitor-preview
/tmp/prosio-agent-monitor-preview /tmp/agent-monitor-light.png
/tmp/prosio-agent-monitor-preview --dark /tmp/agent-monitor-dark.png
/tmp/prosio-agent-monitor-preview --menu /tmp/agent-menu-light.png
/tmp/prosio-agent-monitor-preview --menu --dark /tmp/agent-menu-dark.png
/tmp/prosio-agent-monitor-preview --live-snapshot
```

The preview uses synthetic data and an offscreen window with no Prosio bundle identity. Live snapshot prints counts, sources, state totals and read performance only, with no conversation text, session IDs or credentials. It reads the default `~/.codex`; the production window also respects `CODEX_HOME` and a user-selected folder.

To include the new source files in the main app, regenerate its normal project with `xcodegen generate --spec project.yml` before building. The implementation validation used a separate generated project and derived-data directory so it did not replace the user's running application.
