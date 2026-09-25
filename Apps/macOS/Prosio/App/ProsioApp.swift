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

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }
}
