import AppKit
import Observation
import ProsioAudio
import ProsioCore
import ProsioTranscription
import ServiceManagement
import SwiftUI

/// Composition root. Owned by mac-system agent; UI agent may only READ these properties.
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let dictionary: DictionaryStore
    let history: HistoryStore
    let backend: BackendClient
    let permissions: PermissionsManager
    let focus: FocusContextProvider
    let inserter: TextInserter
    let controller: DictationController
    @ObservationIgnored private(set) var hotkey: HotkeyMonitor?
    @ObservationIgnored private(set) var hud: HUDController?

    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var onboardingWindowDelegate: OnboardingWindowDelegate?

    init() {
        let support = URL.applicationSupportDirectory.appending(path: "Prosio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        settings = AppSettings()
        dictionary = DictionaryStore(fileURL: support.appending(path: "dictionary.json"))
        history = HistoryStore(fileURL: support.appending(path: "history.json"))
        // TODO(P1): if `settings.backendURL` changes at runtime, `backend` (and anything holding
        // a reference to it, e.g. the cloud engine's token provider) would need to be recreated.
        // Not needed for the P0 skeleton, where the URL is effectively fixed at launch.
        backend = BackendClient(baseURL: settings.backendURL)
        permissions = PermissionsManager()
        focus = FocusContextProvider()
        inserter = TextInserter(settings: settings)

        // Live preview: on-device SpeechAnalyzer. Final text: cloud batch Gemini SMART via our backend.
        // (GatewayTranscriptionEngine — live Gemini streaming — stays available but the Gateway live
        // path proved unreliable in testing; see docs/gateway-ws-protocol.md.)
        let engines = EngineSet(
            cloud: CloudBatchTranscriptionEngine(transcriber: backend),
            local: SpeechAnalyzerEngine(locale: Self.previewLocale(for: settings))
        )
        controller = DictationController(
            audio: AudioCapture(),
            engines: engines,
            inserter: inserter,
            contextProvider: focus,
            history: history,
            dictionary: dictionary,
            settings: settings
        )

        let backendRef = backend
        controller.onSessionCompleted = { [weak backendRef] item in
            // Only cloud (gateway.*) sessions count against the user's quota.
            guard item.engineID.hasPrefix("gateway") else { return }
            Task {
                try? await backendRef?.reportUsage(UsageReport(
                    sessionID: item.id,
                    engineID: item.engineID,
                    audioSeconds: item.durationSeconds,
                    startedAt: item.createdAt
                ))
            }
        }
    }

    /// Fallback locale for the on-device preview; the engine re-resolves from `languageHints` per session.
    private static func previewLocale(for settings: AppSettings) -> Locale {
        Locale(identifier: settings.languageHints.first ?? Locale.current.identifier)
    }

    func launch() {
        // Download/prepare on-device speech assets up front so the first dictation previews instantly.
        let locale = Self.previewLocale(for: settings)
        Task.detached(priority: .utility) {
            try? await SpeechAnalyzerEngine.prepareAssets(for: locale)
        }
        hud = HUDController(controller: controller, settings: settings)
        hotkey = HotkeyMonitor(settings: settings, controller: controller)
        hotkey?.start()

        permissions.refresh()
        if !permissions.allRequiredGranted {
            showOnboarding()
        }
    }

    // MARK: - API for UI (signatures frozen; bodies owned by mac-system)

    /// Launch at login via SMAppService.mainApp.
    var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Best-effort for P0: no dedicated error-surface in the UI yet.
                print("Prosio: failed to \(newValue ? "register" : "unregister") launch-at-login: \(error)")
            }
        }
    }

    /// Shows the onboarding window (also used by "Permissions…" menu item).
    func showOnboarding() {
        permissions.refresh()

        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(environment: self, onFinish: { [weak self] in
                self?.onboardingWindow?.close()
            })
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Prosio"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        let delegate = OnboardingWindowDelegate { [weak self] in
            self?.onboardingWindow = nil
        }
        window.delegate = delegate
        onboardingWindowDelegate = delegate
        onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Dev sign-in against `settings.backendURL`, then syncs the dictionary.
    func signIn(email: String) async throws {
        try await backend.devSignIn(email: email)
        await syncDictionaryAfterSignIn()
    }

    func signOut() {
        backend.signOut()
    }

    /// Best-effort last-write-wins merge of the server dictionary into the local store (keeping
    /// server ids so devices converge), then pushes the merged result back.
    private func syncDictionaryAfterSignIn() async {
        guard let remoteEntries = try? await backend.fetchDictionary() else { return }
        try? dictionary.merge(remoteEntries)
        try? await backend.pushDictionary(dictionary.entries)
    }

    #if DEBUG
    /// DEBUG-only menu hook to preview every HUD state (listening/finalizing/finished/failed).
    func showHUDShowcase() {
        hud?.showcase()
    }
    #endif

    func shutdown() {
        hotkey?.stop()
        controller.cancel()
    }
}

/// Small NSWindowDelegate shim so AppEnvironment doesn't need to be an NSObject subclass.
private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
