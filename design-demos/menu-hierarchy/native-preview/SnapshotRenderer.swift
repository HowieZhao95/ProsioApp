import AppKit
import SwiftUI

/// Offscreen native renderer for the shared menu preview view. This never constructs
/// AppEnvironment, launches the application, or requests device permissions.
@MainActor
enum SnapshotRenderer {
    static func write<V: View>(_ view: V, name: String, appearance: NSAppearance.Name,
                               width: CGFloat = 360, output: URL) throws {
        _ = NSApplication.shared
        let colorScheme: ColorScheme = appearance == .darkAqua ? .dark : .light
        let hosting = NSHostingView(rootView: view
            .environment(\.colorScheme, colorScheme)
            .frame(width: width))
        hosting.appearance = NSAppearance(named: appearance)

        // A real AppKit backing window lets materials, text, and SF Symbols resolve as
        // they do in the menu, without ordering the window onscreen.
        let fitting = hosting.fittingSize
        let size = CGSize(width: width, height: max(1, min(1200, fitting.height)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw SnapshotError.bitmapUnavailable
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngUnavailable
        }
        try png.write(to: output.appendingPathComponent(name), options: .atomic)
    }

    private enum SnapshotError: Error { case bitmapUnavailable, pngUnavailable }
}
