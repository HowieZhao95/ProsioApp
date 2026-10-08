import AppKit
import CoreGraphics
import Observation
import ProsioAudio
import ProsioCore
import ProsioTranscription
import ServiceManagement
import SwiftUI

/// Surfaced to the UI (read-only) so it can explain *why* dictation isn't working and offer a
/// fix, instead of the hotkey just silently doing nothing.
enum HotkeyStatus: Equatable {
    /// Everything looks good; the trigger key should work.
    case ready
    /// Accessibility isn't granted, so the (active) event tap can't receive key events.
    case missingAccessibility
    /// The tap exists but is currently disabled (system timeout/suspicious input) and hasn't
    /// been re-enabled yet.
    case tapDisabled
    /// `triggerKey == .fn` and System Settings > Keyboard > "Press \u{1F310} key to" is set to
    /// something other than the default (commonly "Start Dictation", which competes with us for
    /// both the fn key and the microphone). We can't change that setting for the user, only tell
    /// them about it.
    case fnKeyConflict
}

/// Composition root. Owned by mac-system agent; UI agent may only READ these properties.
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let dictionary: DictionaryStore
    let history: HistoryStore
    let backend: BackendClient
    let capture: CaptureCoordinator
    let meeting: MeetingCoordinator
    let recording: RecordingCoordinator
    let presentation: PresentationCoordinator
    let notes: DailyNotesCoordinator
    let permissions: PermissionsManager
    let focus: FocusContextProvider
    let inserter: TextInserter
    let controller: DictationController
    let onboarding: OnboardingProgress
    @ObservationIgnored private(set) var hotkey: HotkeyMonitor?
    @ObservationIgnored private(set) var hud: HUDController?
    @ObservationIgnored private let audioCapture: AudioCapture

    /// Whether the backend has a stored session (kept in sync explicitly since `BackendClient`
    /// isn't itself `@Observable`; see `signIn`/`signOut`).
    private(set) var isSignedIn: Bool
    /// The signed-in account's email, mirrored from `backend.signedInEmail` at the same points
    /// `isSignedIn` is (init, `onSignInStateChange`, `signIn`/`signOut`) — `nil` when signed out.
    private(set) var signedInEmail: String?

    #if DEBUG
    @ObservationIgnored private var presentationTestWindow: NSWindow?
    #endif
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var onboardingWindowDelegate: OnboardingWindowDelegate?
    @ObservationIgnored var isTerminating = false

    init(supportDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        let support = supportDirectory ?? URL.applicationSupportDirectory.appending(path: "Prosio", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        settings = AppSettings(defaults: defaults)
        onboarding = OnboardingProgress(defaults: defaults)
        dictionary = DictionaryStore(fileURL: support.appending(path: "dictionary.json"))
        history = HistoryStore(fileURL: support.appending(path: "history.json"))
        // TODO(P1): if `settings.backendURL` changes at runtime, `backend` (and anything holding
        // a reference to it, e.g. the cloud engine's token provider) would need to be recreated.
        // Not needed for the P0 skeleton, where the URL is effectively fixed at launch.
        backend = BackendClient(baseURL: settings.backendURL)
        isSignedIn = backend.isSignedIn
        signedInEmail = backend.signedInEmail
        presentation = PresentationCoordinator(defaults: defaults)
        notes = DailyNotesCoordinator(root: support.appending(path: "Notes", directoryHint: .isDirectory), defaults: defaults)
        permissions = PermissionsManager()
        capture = CaptureCoordinator(permissions: permissions, rootURL: support.appending(path: "Captures", directoryHint: .isDirectory))
        let captureBackend = backend
        capture.translateTexts = { texts, language in
            try await captureBackend.translateCaptureTexts(texts, targetLanguage: language)
        }
        meeting = MeetingCoordinator(root: support.appending(path: "Meetings", directoryHint: .isDirectory), permissions: permissions, backend: backend, settings: settings)
        recording = RecordingCoordinator(root: support.appending(path: "Recordings", directoryHint: .isDirectory), permissions: permissions)
        focus = FocusContextProvider()
        inserter = TextInserter(settings: settings)
        let practiceFocus = focus
        inserter.practiceTarget = { [weak practiceFocus] in practiceFocus?.practiceTarget }

        // Live preview: on-device SpeechAnalyzer. Final text: one /api/transcribe request with the
        // silence-trimmed Ogg/Opus audio + the local transcript; the server decides (Jev) whether
        // the local text is good enough (no Gemini call) and which mode the utterance is.
        let audio = AudioCapture()
        audioCapture = audio
        let cloudTranscriber = backend
        controller = DictationController(
            audio: audio,
            localEngine: SpeechAnalyzerEngine(locale: Self.previewLocale(for: settings)),
            cloudTranscriber: backend,
            inserter: inserter,
            contextProvider: focus,
            history: history,
            dictionary: dictionary,
            settings: settings,
            audioPreparer: SilenceTrimmingOpusAudioPreparer(),
            prewarmCloud: { await cloudTranscriber.prewarm() },
            composer: backend
        )

        let feedback = DictationSoundFeedback()
        controller.onRecordingStarted = {
            AgentMonitorCoordinator.shared.voice.cancel()
            feedback.playStart()
        }
        controller.onRecordingStopped = { feedback.playStop() }

        AgentMonitorCoordinator.shared.voice.factory = { [weak self] target in
            guard let self else { throw CancellationError() }
            switch self.controller.phase {
            case .idle, .finished, .failed: break
            default: throw ProsioError.audioUnavailable("Voice input is already active")
            }
            guard !self.recording.blocksOtherCapture, self.meeting.activeID == nil,
                  !self.meeting.starting, !self.meeting.finishingRecording else {
                throw ProsioError.audioUnavailable("Another recording is active")
            }
            await self.permissions.request(.microphone)
            guard !Task.isCancelled, self.permissions.statuses[.microphone] == .granted else { throw CancellationError() }
            switch self.controller.phase {
            case .idle, .finished, .failed: break
            default: throw ProsioError.audioUnavailable("Voice input is already active")
            }
            guard !self.recording.blocksOtherCapture, self.meeting.activeID == nil,
                  !self.meeting.starting, !self.meeting.finishingRecording else {
                throw ProsioError.audioUnavailable("Another recording is active")
            }
            let audio = AudioCapture()
            let input = try audio.start()
            let engine = SpeechAnalyzerEngine(locale: Self.previewLocale(for: self.settings))
            let events = engine.transcribe(audio: input, options: TranscriptionOptions(vocabulary: target.vocabulary, languageHints: self.settings.languageHints))
            let pair = AsyncThrowingStream<String, Error>.makeStream()
            let transcription = Task {
                do {
                    for try await event in events {
                        switch event { case .partial(let text), .final(let text): pair.continuation.yield(text) }
                    }
                    pair.continuation.finish()
                } catch { pair.continuation.finish(throwing: error) }
            }
            pair.continuation.onTermination = { @Sendable _ in audio.stop(); transcription.cancel() }
            return AgentVoiceStream(text: pair.stream, stop: { audio.stop() }, cancel: { audio.stop(); transcription.cancel() })
        }

        // Cloud usage is recorded by the server, never by client reports.

    }

    /// Fallback locale for the on-device preview; the engine re-resolves from `languageHints` per session.
    private static func previewLocale(for settings: AppSettings) -> Locale {
        Locale(identifier: settings.languageHints.first ?? Locale.current.identifier)
    }

    func launch() {
        Task { await recording.recoverSavedSessions() }
        // The stored session token loads asynchronously; reading `isSignedIn` at init is too early.
        backend.onSignInStateChange = { [weak self] signedIn in
            Task { @MainActor in
                guard let self else { return }
                self.isSignedIn = signedIn
                // `signedInEmail` is documented as current by the time this fires.
                self.signedInEmail = self.backend.signedInEmail
            }
        }
        // Download/prepare on-device speech assets up front so the first dictation previews instantly.
        let locale = Self.previewLocale(for: settings)
        Task.detached(priority: .utility) {
            try? await SpeechAnalyzerEngine.prepareAssets(for: locale)
        }
        // Build the audio graph up front (mic stays off) so the first press starts recording fast.
        if permissions.statuses[.microphone] == .granted {
            audioCapture.prewarm()
        }
        hud = HUDController(controller: controller, settings: settings)
        capture.canBegin = { [weak self] in
            guard let self else { return false }
            guard !self.recording.blocksOtherCapture, self.meeting.activeID == nil,
                  !self.meeting.starting, !self.meeting.finishingRecording else { return false }
            switch self.controller.phase { case .idle, .finished, .failed: return true; default: return false }
        }
        recording.canBegin = { [weak self] in
            guard let self, !self.capture.isBusy, self.meeting.activeID == nil,
                  !self.meeting.starting, !self.meeting.finishingRecording,
                  !AgentMonitorCoordinator.shared.voice.recording, !AgentMonitorCoordinator.shared.voice.finishing else { return false }
            switch self.controller.phase { case .idle, .finished, .failed: return true; default: return false }
        }
        meeting.canBegin = { [weak self] in
            guard let self, !self.capture.isBusy, !self.recording.blocksOtherCapture,
                  !AgentMonitorCoordinator.shared.voice.recording, !AgentMonitorCoordinator.shared.voice.finishing else { return false }
            switch self.controller.phase { case .idle, .finished, .failed: return true; default: return false }
        }
        hotkey = HotkeyMonitor(settings: settings, controller: controller)
        recording.onActivity = { [weak self] active in self?.hotkey?.isRecordingSuspended = active }
        meeting.onRecordingActivity = { [weak self] active in self?.hotkey?.isMeetingSuspended = active }
        capture.onSelectionActivity = { [weak self] active in
            self?.hotkey?.isCaptureSuspended = active
            self?.presentation.setEnvironmentSuspended(active)
        }
        let captureHotkey = CaptureHotkey { [weak self] in self?.capture.start(.region) }
        capture.hotkey = captureHotkey
        captureHotkey.onShortcutChange = { [weak self] in self?.hotkey?.resetCaptureOptionGesture() }
        hotkey?.isOptionCaptureSelected = { [weak self] in self?.capture.hotkey?.shortcut == .optionEitherSide }
        hotkey?.isOptionCaptureBusy = { [weak self] in
            guard let self else { return true }
            return self.capture.isBusy || !self.capture.canBegin()
        }
        hotkey?.onOptionCaptureTap = { [weak self] in
            guard let self else { return }
            let wasBusy = self.capture.isBusy
            self.capture.start(.region)
            ProsioLog.hotkey.notice("option capture.start returned busyBefore=\(wasBusy, privacy: .public) busyAfter=\(self.capture.isBusy, privacy: .public) screenPermission=\(self.permissions.screenCaptureGranted, privacy: .public) messagePresent=\(self.capture.message != nil, privacy: .public)")
        }
        hotkey?.start()
        captureHotkey.start()

        presentation.isControlShortcut = { [weak self] code, flags in
            guard let shortcut = self?.capture.hotkey?.shortcut,
                  flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskControl, .maskShift] else { return false }
            return (shortcut == .controlShift2 && code == 19) || (shortcut == .controlShift3 && code == 20)
        }
        presentation.launch()
        notes.launch()
        #if DEBUG
        // Opt-in live QA enters the real ScreenCaptureKit/editor path without a menu-bar click.
        if CommandLine.arguments.contains("--capture-test") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.capture.start(.region)
            }
        }
        // Opt-in QA window reuses the exact production views, allowing native UI automation
        // without relying on a transient menu-bar popover. Normal launches never create it.
        if ProcessInfo.processInfo.environment["PROSIO_PRESENTATION_TEST_PANEL"] == "1" {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 520, height: 640),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Prosio 演示验收"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TabView {
                ScrollView { PresentationMenuView(coordinator: presentation, permissions: permissions).padding(.top, 16) }
                    .tabItem { Text("演示操作") }
                PresentationSettingsView(coordinator: presentation).tabItem { Text("演示设置") }
            })
            presentationTestWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        #endif
        permissions.refresh()
        // Permission requests are user-initiated per feature. Presentation-only users need
        // neither microphone nor screen-recording access; voice exposes its onboarding button.
        if onboarding.shouldPresentOnLaunch { showOnboarding(resume: true) }
    }

    var optionCaptureAvailability: HotkeyRouting.OptionCaptureAvailability {
        HotkeyRouting.optionCaptureAvailability(
            voiceUsesRightOption: settings.triggerKey == .rightOption,
            accessibilityGranted: permissions.statuses[.accessibility] == .granted,
            inputMonitoringGranted: permissions.statuses[.inputMonitoring] == .granted,
            tapHealthy: hotkey?.isTapHealthy == true
        )
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
    func showOnboarding(resume: Bool = false) {
        permissions.refresh()

        if let onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            onboardingWindow.makeKeyAndOrderFront(nil)
            return
        }
        if !resume { onboarding.reopen() }
        var size = OnboardingStyle.windowSize
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "ProsioOnboardingValidation") as? Bool == true {
            size = CGSize(width: 760, height: 610)
        }
        #endif
        let hosting = NSHostingController(
            rootView: OnboardingView(environment: self, onFinish: { [weak self] in
                self?.onboardingWindow?.close()
            }, canvasSize: size)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Prosio · 开始使用"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()

        let delegate = OnboardingWindowDelegate { [weak self] in
            guard let self else { return }
            self.onboarding.handleWindowClose(isTerminating: self.isTerminating)
            self.onboardingWindow = nil
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
        isSignedIn = backend.isSignedIn
        signedInEmail = backend.signedInEmail
        await syncDictionaryAfterSignIn()
    }

    func signOut() {
        backend.signOut()
        isSignedIn = backend.isSignedIn
        signedInEmail = backend.signedInEmail
    }

    /// Status of the global hotkey, for the UI to explain a non-working trigger key and offer a
    /// fix instead of it just silently doing nothing. `fnKeyConflict` takes priority since it's
    /// the root cause even when the tap itself looks healthy.
    ///
    /// Checks `CGPreflightListenEventAccess()` directly rather than the cached
    /// `permissions.statuses[.inputMonitoring]`: that cache is only refreshed on launch and app
    /// activation, and `HotkeyMonitor`'s own logs showed the tap being denied/disabled while the
    /// cached status could plausibly lag — this read is synchronous and effectively free, so
    /// there's no reason to risk showing `tapDisabled` when the real cause is missing permission.
    var hotkeyStatus: HotkeyStatus {
        if settings.triggerKey == .fn, Self.fnKeyUsedBySystemDictation() {
            return .fnKeyConflict
        }
        if !AXIsProcessTrusted() {
            return .missingAccessibility
        }
        if let hotkey, !hotkey.isTapHealthy {
            return .tapDisabled
        }
        return .ready
    }

    /// `AppleFnUsageType` in the `com.apple.HIToolbox` domain controls System Settings > Keyboard
    /// > "Press \u{1F310} key to". 0 is the default ("Show Emoji & Symbols" — no conflict with
    /// us). Any other value means the user has explicitly reassigned the fn key to something
    /// else system-wide (commonly 3 = "Start Dictation", which fights us for both the key and the
    /// microphone) — we surface that as a conflict so the user understands why fn doesn't work,
    /// even though we can't change the setting for them.
    private static func fnKeyUsedBySystemDictation() -> Bool {
        guard let usage = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int else {
            return false
        }
        return usage != 0
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
        presentation.shutdown()
        notes.shutdown()
        capture.shutdown()
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
