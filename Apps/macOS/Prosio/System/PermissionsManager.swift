import AppKit
@preconcurrency import ApplicationServices
import AVFAudio
import CoreGraphics
import Observation
import Speech

enum PermissionKind: CaseIterable, Hashable {
    case microphone, accessibility, inputMonitoring, speechRecognition
}

enum PermissionStatus: Hashable {
    case granted, denied, notDetermined
}

/// Checks and requests TCC permissions. Owned by mac-system agent. API FROZEN.
@Observable
final class PermissionsManager {
    private(set) var screenCaptureGranted = false
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    // `deinit` runs nonisolated even on a main-actor-isolated class, so this can't be a normal
    // (isolated) stored property if we want to clean it up there.
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    var allRequiredGranted: Bool {
        // The hotkey uses an active event tap, which needs Accessibility but not Input Monitoring.
        [.microphone, .accessibility].allSatisfy { statuses[$0] == .granted }
    }

    init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this runs on the main thread/MainActor's executor.
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func refresh() {
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        set(.microphone, Self.microphoneStatus())
        set(.accessibility, AXIsProcessTrusted() ? .granted : .denied)
        set(.inputMonitoring, Self.inputMonitoringStatus())
        set(.speechRecognition, Self.speechRecognitionStatus())
    }

    private func set(_ kind: PermissionKind, _ newStatus: PermissionStatus) {
        let previous = statuses[kind]
        guard previous != newStatus else { return }
        statuses[kind] = newStatus
        ProsioLog.permissions.info("\(String(describing: kind), privacy: .public): \(String(describing: previous), privacy: .public) -> \(String(describing: newStatus), privacy: .public)")
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVAudioApplication.requestRecordPermission()
        case .accessibility:
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                // TCC calls back on a background queue. `@Sendable` keeps this closure from
                // inheriting the module's default MainActor isolation, which would trap at runtime.
                SFSpeechRecognizer.requestAuthorization { @Sendable _ in
                    continuation.resume()
                }
            }
        }
        refresh()
    }

    /// User-initiated recovery for the standalone right-Option screenshot shortcut.
    /// Request first so Prosio appears in the system list; if denied, open that pane.
    func recoverInputMonitoring() async {
        await request(.inputMonitoring)
        if statuses[.inputMonitoring] != .granted {
            openSystemSettings(for: .inputMonitoring)
        }
    }

    /// Opens the matching pane in System Settings.
    func openSystemSettings(for kind: PermissionKind) {
        let suffix: String
        switch kind {
        case .microphone: suffix = "Privacy_Microphone"
        case .accessibility: suffix = "Privacy_Accessibility"
        case .inputMonitoring: suffix = "Privacy_ListenEvent"
        case .speechRecognition: suffix = "Privacy_SpeechRecognition"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }

    // Capture is independent of the microphone and Accessibility permissions used by voice.
    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }
    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Status lookups

    private static func microphoneStatus() -> PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func inputMonitoringStatus() -> PermissionStatus {
        // CGPreflightListenEventAccess doesn't distinguish "denied" from "never asked"; for our
        // purposes (gating features, prompting the user) either non-granted state is treated the
        // same, so this collapses to granted/denied.
        CGPreflightListenEventAccess() ? .granted : .denied
    }

    private static func speechRecognitionStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
