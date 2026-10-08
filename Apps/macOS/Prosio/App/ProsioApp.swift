import SwiftUI

@main
struct ProsioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(environment: appDelegate.environment)
        } label: {
            AgentMenuStatusLabel(coordinator: .shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView(environment: appDelegate.environment)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private static var isOnboardingValidation: Bool {
        CommandLine.arguments.contains("--onboarding-ui-validation") ||
            Bundle.main.object(forInfoDictionaryKey: "ProsioOnboardingValidation") as? Bool == true
    }
    #endif
    let environment: AppEnvironment = {
        #if DEBUG
        if CommandLine.arguments.contains("--onboarding-render") || isOnboardingValidation {
            let root = FileManager.default.temporaryDirectory.appending(path: "prosio-onboarding-render-\(UUID().uuidString)", directoryHint: .isDirectory)
            let defaults = UserDefaults(suiteName: "prosio-onboarding-render-\(UUID().uuidString)")!
            return AppEnvironment(supportDirectory: root, defaults: defaults)
        }
        #endif
        return AppEnvironment()
    }()
    private var finishingMedia = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if Self.isOnboardingValidation {
            // The isolated editor still needs its document identity and draft loaded.
            // No global shortcut or media service is started in this UI validation mode.
            environment.notes.launch(enableShortcut: false)
            environment.showOnboarding()
            return
        }
        if CommandLine.arguments.contains("--onboarding-render") {
            OnboardingRenderer.render(environment: environment)
            return
        }
        #endif
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
        AgentMonitorCoordinator.shared.restoreMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentMonitorCoordinator.shared.stop(persistPreference: false)
        environment.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard environment.notes.editorReady || environment.notes.dirty || environment.meeting.activeID != nil || environment.meeting.starting || environment.meeting.finishingRecording || environment.recording.blocksOtherCapture else {
            environment.isTerminating = true
            return .terminateNow
        }
        guard !finishingMedia else { return .terminateLater }
        finishingMedia = true
        Task { @MainActor in
            guard await environment.notes.flush(allowDiskFailure: true) else {
                let alert = NSAlert()
                alert.messageText = "便签内容尚未安全保留"
                alert.informativeText = environment.notes.recoveryError ?? environment.notes.message ?? "请先完成当前输入，再退出。"
                alert.addButton(withTitle: "取消退出")
                alert.runModal()
                finishingMedia = false
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await environment.recording.flushForTermination()
            await environment.meeting.flushForTermination()
            environment.isTerminating = true
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
