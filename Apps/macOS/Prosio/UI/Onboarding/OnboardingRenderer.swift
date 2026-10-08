#if DEBUG
import AppKit
import SwiftUI

/// Offscreen QA uses the production view, isolated defaults and temporary document stores.
/// It never launches hotkeys, media services or Agent monitoring and never asks for permissions.
enum OnboardingRenderer {
    static func render(environment: AppEnvironment) {
        guard let index = CommandLine.arguments.firstIndex(of: "--onboarding-render"),
              CommandLine.arguments.count > index + 1 else { return }
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let dark = CommandLine.arguments.contains("--dark")
        let compact = CommandLine.arguments.contains("--compact")
        let size = compact ? CGSize(width: 760, height: 610) : CGSize(width: 1000, height: 650)
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Task { @MainActor in
            for page in OnboardingPage.allCases {
                environment.onboarding.select(page)
                let view = NSHostingView(rootView: OnboardingView(environment: environment, onFinish: {}, canvasSize: size))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(220))
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    let url = destination.appending(path: "\(page.rawValue + 1)-\(page.title)\(dark ? "-dark" : "").png")
                    try? data.write(to: url)
                    print("Rendered \(url.path)")
                }
                window.close()
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
