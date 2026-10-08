# Distribution capability probe

Run from the repository root:

```sh
python3 tools/distribution-probe/run.py
```

Requires macOS, Xcode command-line tools, and the local `Prosio Local Development`
signing identity. Set `PROSIO_PROBE_SIGNING_IDENTITY` to select another identity.
Builds and evidence go to `.build/distribution-probe/` (gitignored).

The runner compiles one Swift source and signs two identical app bundles, differing
only in `com.apple.security.app-sandbox`. Each run gets a fresh disposable AppKit
text fixture. It tests:

- reading that fixture's selected text through `AXUIElement`;
- creating/enabling the same active session event tap used by Prosio;
- posting Cmd+V specifically to the fixture PID, then observing the paste;
- reading a non-sensitive file outside the container as a sandbox control.

The fixture remains in the background. Events are PID-addressed, so this does not
exercise foreground selection/restoration or the exact global `CGEvent.post`
route used by the shipping app. Only marker-match booleans are logged. The
clipboard is temporarily changed; all previous representations are restored if
no other application has changed it in the meantime. The fixture is terminated
in a `finally` block. No Prosio installation or TCC records are modified.

These executables are launched by a development host with existing Accessibility
and Input Monitoring authorization. They may inherit the host's TCC attribution.
The outside-file denial establishes that the sandbox is active. An API succeeding
here is **not** proof it will receive permission in a freshly installed App Store
build, nor proof of App Review acceptance. A failure despite granted TCC is a
useful incompatibility signal. No temporary/private entitlement is used.

See `docs/P1-COMMERCIALIZATION.md` for the decision and limitations.
