import AppKit

/// A transient selection surface; it never captures or stores desktop pixels.
final class RecordingRegionSelector {
    private var panel: RecordingSelectionPanel?
    private let screen: NSScreen
    private let completion: (CGRect?) -> Void

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.screen = screen
        self.completion = completion
    }

    func begin() {
        let panel = RecordingSelectionPanel(contentRect: screen.frame, styleMask: .borderless,
                                            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let selection = RecordingSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        selection.completion = { [weak self] rect in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
            completion(rect)
        }
        panel.contentView = selection
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(selection)
    }
}

private final class RecordingSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RecordingSelectionView: NSView {
    var completion: ((CGRect?) -> Void)?
    private var origin: CGPoint?
    private var selection: CGRect?
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y),
                           width: abs(origin.x - p.x), height: abs(origin.y - p.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        guard let selection, selection.width >= 16, selection.height >= 16 else { return }
        completion?(selection.integral)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion?(nil) } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        bounds.fill()
        if let selection {
            NSColor.white.withAlphaComponent(0.08).setFill()
            selection.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 2
            path.stroke()
        }
        let hint = "拖动框选录制区域 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = hint.size(withAttributes: attributes)
        let box = CGRect(x: (bounds.width - size.width) / 2 - 16, y: bounds.height - 78,
                         width: size.width + 32, height: 42)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()
        hint.draw(at: CGPoint(x: box.minX + 16, y: box.minY + 12), withAttributes: attributes)
    }
}
