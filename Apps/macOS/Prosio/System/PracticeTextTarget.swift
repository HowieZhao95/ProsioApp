import AppKit
import ProsioCore

/// A captured local target prevents practice text from being pasted into another app if focus
/// changes during transcription. Only the dedicated onboarding editor adopts this protocol.
@MainActor
protocol PracticeTextTarget: AnyObject {
    var practiceIdentifier: String { get }
    var practiceSelectedText: String? { get }
    var practiceAvailable: Bool { get }
    func preparePracticeInsertion()
    func insertPracticeText(_ text: String) -> Bool
}

enum PracticeTextRouting {
    static let prefix = "prosio-practice:"
    static func context(for target: any PracticeTextTarget) -> FocusContext {
        target.preparePracticeInsertion()
        return FocusContext(bundleID: Bundle.main.bundleIdentifier, appName: "Prosio",
                     processID: ProcessInfo.processInfo.processIdentifier,
                     windowTitle: prefix + target.practiceIdentifier,
                     selectedText: target.practiceSelectedText)
    }
    static func isPractice(_ context: FocusContext?) -> Bool {
        context?.processID == ProcessInfo.processInfo.processIdentifier &&
        context?.windowTitle?.hasPrefix(prefix) == true
    }
    static func matches(_ target: any PracticeTextTarget, context: FocusContext?) -> Bool {
        isPractice(context) && context?.windowTitle == prefix + target.practiceIdentifier && target.practiceAvailable
    }
}
