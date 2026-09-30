import AppKit
import Testing

@Suite("Pinned screenshot window", .serialized)
@MainActor
struct CapturePinnedWindowTests {
    private func image() throws -> CGImage { try CaptureEditorTestPixels.image(width: 320, height: 200) }

    private func event(_ type: NSEvent.EventType, point: CGPoint, view: NSView) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @Test("Pinned image stays floating, moves freely, resizes proportionally, and closes independently")
    func dragResizeClose() throws {
        _ = NSApplication.shared
        let window = CapturePinnedWindow(image: try image())
        defer { window.close() }
        let view = try #require(window.contentView as? CapturePinnedImageView)
        #expect(window.level == .floating)
        #expect(abs(window.frame.width / window.frame.height - 1.6) < 0.01)

        let original = window.frame
        let start = CGPoint(x: min(90, view.bounds.midX), y: min(70, view.bounds.midY))
        view.mouseDown(with: try event(.leftMouseDown, point: start, view: view))
        view.mouseDragged(with: try event(.leftMouseDragged,
            point: CGPoint(x: start.x + 42, y: start.y + 24), view: view))
        view.mouseUp(with: try event(.leftMouseUp, point: start, view: view))
        #expect(abs(window.frame.minX - original.minX - 42) < 1)
        #expect(abs(window.frame.minY - original.minY - 24) < 1)

        let moved = window.frame
        let grip = CGPoint(x: view.bounds.maxX - 12, y: 12)
        view.mouseDown(with: try event(.leftMouseDown, point: grip, view: view))
        view.mouseDragged(with: try event(.leftMouseDragged,
            point: CGPoint(x: grip.x + 60, y: grip.y), view: view))
        view.mouseUp(with: try event(.leftMouseUp, point: grip, view: view))
        #expect(window.frame.width > moved.width + 50)
        #expect(abs(window.frame.width / window.frame.height - 1.6) < 0.01)
        #expect(abs(window.frame.maxY - moved.maxY) < 1)

        var closes = 0
        window.onClose = { closes += 1 }
        let closePoint = CGPoint(x: view.bounds.maxX - 15, y: view.bounds.maxY - 15)
        view.mouseDown(with: try event(.leftMouseDown, point: closePoint, view: view))
        #expect(closes == 1)
    }
}
