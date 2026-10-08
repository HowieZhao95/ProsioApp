import AppKit
import SwiftUI
import Darwin

@main struct NotesValidationApp: App {
    @NSApplicationDelegateAdaptor(NotesValidationDelegate.self) var delegate
    var body: some Scene {
        Settings { NotesSettingsView(notes: delegate.notes).frame(width: 520, height: 460) }
    }
}

@MainActor final class NotesValidationDelegate: NSObject, NSApplicationDelegate {
    let notes: DailyNotesCoordinator
    let root: URL
    override init() {
        root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROSIO_NOTES_VALIDATION_ROOT"] ?? "/tmp/prosio-notes-native-validation", isDirectory: true)
        let files = root.appendingPathComponent("notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let today = NoteDay(), calendar = Calendar(identifier: .gregorian)
        let yesterday = NoteDay(calendar.date(byAdding: .day, value: -1, to: today.date)!)
        let sample = "# 今天先记下\n\n先把想法留下，再回到手头的事。\n\n## 接下来\n\n- [ ] 整理会议中的三个要点\n- [ ] 把下一步写下来\n\n> 少打断一次。\n"
        if !FileManager.default.fileExists(atPath: files.appendingPathComponent(today.key + ".md").path) {
            try? Data(sample.utf8).write(to: files.appendingPathComponent(today.key + ".md"))
            try? Data("# 昨天的记录\n\n回看昨天留下的想法。".utf8).write(to: files.appendingPathComponent(yesterday.key + ".md"))
        }
        let suite = ProcessInfo.processInfo.arguments.contains("--validate-animation") ? "app.prosio.validation.notes.animation.preferences" : "app.prosio.validation.notes.preferences"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(files.path, forKey: "prosio.notes.directory")
        notes = DailyNotesCoordinator(root: root.appendingPathComponent("recovery"), defaults: defaults)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        notes.launch(enableShortcut: false)
        notes.show()
        if ProcessInfo.processInfo.arguments.contains("--validate-animation") {
            Task { await validateAnimation() }
        }
    }
    private func validateAnimation() async {
        for _ in 0..<50 where !notes.editorReady { try? await Task.sleep(for: .milliseconds(100)) }
        guard let panel = NSApp.windows.first(where: { $0 is NotesPanel }) else { NSApp.terminate(nil); return }
        var checks: [String: Bool] = [:]
        try? await Task.sleep(for: .milliseconds(240))
        checks["show"] = panel.isVisible && panel.alphaValue > 0.99
        notes.hide()
        try? await Task.sleep(for: .milliseconds(300))
        checks["hide"] = !panel.isVisible && panel.alphaValue > 0.99
        notes.show()
        try? await Task.sleep(for: .milliseconds(30))
        notes.hide()
        try? await Task.sleep(for: .milliseconds(30))
        notes.show()
        try? await Task.sleep(for: .milliseconds(280))
        checks["reverseFade"] = panel.isVisible && panel.alphaValue > 0.99
        notes.hide(); notes.show()
        try? await Task.sleep(for: .milliseconds(280))
        checks["cancelPendingHide"] = panel.isVisible && panel.alphaValue > 0.99
        let data = try? JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys, .prettyPrinted])
        if let data {
            try? data.write(to: root.appendingPathComponent("animation-check.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        }
        notes.shutdown()
        Darwin.exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { sender.reply(toApplicationShouldTerminate: await notes.flush(allowDiskFailure: true)) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { notes.shutdown() }
}
