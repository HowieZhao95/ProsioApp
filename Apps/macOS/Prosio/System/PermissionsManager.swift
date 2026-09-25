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
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    // `deinit` runs nonisolated even on a main-actor-isolated class, so this can't be a normal
    // (isolated) stored property if we want to clean it up there.
    @ObservationIgnored nonisolated(unsafe) private var activationObserver: NSObjectProtocol?

    var allRequiredGranted: Bool {
        [.microphone, .accessibility, .inputMonitoring].allSatisfy { statuses[$0] == .granted }
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
        statuses[.microphone] = Self.microphoneStatus()
        statuses[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        statuses[.inputMonitoring] = Self.inputMonitoringStatus()
        statuses[.speechRecognition] = Self.speechRecognitionStatus()
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
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }
        refresh()
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
