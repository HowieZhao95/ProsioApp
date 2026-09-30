import SwiftUI

@main
struct ProsioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Prosio", systemImage: "waveform") {
            MenuBarContentView(environment: appDelegate.environment)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView(environment: appDelegate.environment)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var finishingMedia = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `ProsioTests` launches `Prosio` itself as its XCTest host process. That host must never
        // install a real event tap or touch permissions/onboarding — doing so would fight a real,
        // separately-running Prosio instance for the keyboard/mic during a test run — and
        // terminating here (the duplicate-instance check below) would exit before the test bundle
        // finishes bootstrapping. So: do nothing environment-launching at all when we're a test host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Two real instances would each install their own global event tap and, once dictating,
        // open the microphone — actively harmful, not just wasteful (they'd fight over both).
        // Bail out before `environment.launch()` does any of that if another instance is running.
        if let existing = Self.otherRunningInstance() {
            ProsioLog.lifecycle.info("another Prosio instance is already running (pid \(existing.processIdentifier, privacy: .public)); activating it and quitting this launch")
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        environment.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard environment.meeting.activeID != nil || environment.meeting.starting || environment.meeting.finishingRecording || environment.recording.isBusy else { return .terminateNow }
        guard !finishingMedia else { return .terminateLater }
        finishingMedia = true
        Task { @MainActor in
            await environment.recording.flushForTermination()
            await environment.meeting.flushForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private static func otherRunningInstance() -> NSRunningApplication? {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.prosio.mac"
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
    }
}
