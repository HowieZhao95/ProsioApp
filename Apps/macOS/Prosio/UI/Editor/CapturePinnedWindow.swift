import AppKit

/// A screenshot pinned above ordinary windows. Its image and window remain independent of the editor session.
@MainActor
final class CapturePinnedWindow: NSWindow {
    let image: CGImage
    var onClose: (() -> Void)?
    private var didClose = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(image: CGImage, screen: NSScreen? = NSScreen.main) {
        self.image = image
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = screen?.backingScaleFactor ?? 1
        let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let factor = min(1, visible.width * 0.72 / natural.width, visible.height * 0.72 / natural.height)
        let size = CGSize(width: max(1, natural.width * factor), height: max(1, natural.height * factor))
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = CapturePinnedImageView(frame: CGRect(origin: .zero, size: size), image: image)
        setAccessibilityLabel("Pinned screenshot")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
            close()
        } else { super.keyDown(with: event) }
    }

    override func close() {
        guard !didClose else { return }
        didClose = true
        super.close()
        onClose?()
    }
}

@MainActor
final class CapturePinnedImageView: NSView {
    private enum DragMode { case move, resize }
    let image: CGImage
    private var dragMode: DragMode?
    private var dragStartPointer: CGPoint = .zero
    private var dragStartFrame: CGRect = .zero
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel("Pinned screenshot. Drag to move, drag the lower-right corner or pinch to resize, Escape to close.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); trackingArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) { NSCursor.arrow.set() }
        else if resizeRect.contains(point) { NSCursor.resizeLeftRight.set() }
        else { NSCursor.openHand.set() }
    }

    private var closeRect: CGRect { CGRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 30, height: 30) }
    private var resizeRect: CGRect { CGRect(x: bounds.maxX - 30, y: bounds.minY, width: 30, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero,
            operation: .copy, fraction: 1, respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high])
        NSColor.black.withAlphaComponent(0.32).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        guard hovered else { return }
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: closeRect.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill()
        let x = NSBezierPath()
        x.move(to: CGPoint(x: closeRect.midX - 4, y: closeRect.midY - 4))
        x.line(to: CGPoint(x: closeRect.midX + 4, y: closeRect.midY + 4))
        x.move(to: CGPoint(x: closeRect.midX - 4, y: closeRect.midY + 4))
        x.line(to: CGPoint(x: closeRect.midX + 4, y: closeRect.midY - 4))
        x.lineWidth = 1.6; NSColor.white.setStroke(); x.stroke()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: resizeRect.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill()
        let grip = NSBezierPath()
        for offset in [0.0, 5.0, 10.0] {
            grip.move(to: CGPoint(x: resizeRect.maxX - 7 - offset, y: resizeRect.minY + 7))
            grip.line(to: CGPoint(x: resizeRect.maxX - 7, y: resizeRect.minY + 7 + offset))
        }
        grip.lineWidth = 1.2; NSColor.white.withAlphaComponent(0.9).setStroke(); grip.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point) { window.close(); return }
        window.makeKeyAndOrderFront(nil)
        dragMode = resizeRect.contains(point) ? .resize : .move
        dragStartPointer = window.convertPoint(toScreen: event.locationInWindow)
        dragStartFrame = window.frame
        if dragMode == .move { NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragMode else { return }
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: pointer.x - dragStartPointer.x, height: pointer.y - dragStartPointer.y)
        switch dragMode {
        case .move:
            window.setFrameOrigin(CGPoint(x: dragStartFrame.minX + delta.width,
                                          y: dragStartFrame.minY + delta.height))
        case .resize:
            let ratio = CGFloat(image.width) / CGFloat(image.height)
            let horizontal = delta.width
            let vertical = -delta.height * ratio
            let change = abs(horizontal) >= abs(vertical) ? horizontal : vertical
            let minimumWidth = max(96, 72 * ratio)
            let maximumWidth = min(3200, max(minimumWidth, (window.screen?.visibleFrame.width ?? 1200) * 0.95))
            let width = min(max(dragStartFrame.width + change, minimumWidth), maximumWidth)
            let height = width / ratio
            window.setFrame(CGRect(x: dragStartFrame.minX, y: dragStartFrame.maxY - height,
                                   width: width, height: height), display: true)
        }
    }
    override func mouseUp(with event: NSEvent) { dragMode = nil; NSCursor.arrow.set() }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { super.scrollWheel(with: event); return }
        zoom(by: 1 + event.scrollingDeltaY * 0.012, at: convert(event.locationInWindow, from: nil))
    }
    private func zoom(by factor: CGFloat, at point: CGPoint) {
        guard let window, factor.isFinite, factor > 0 else { return }
        let frame = window.frame
        let ratio = CGFloat(image.width) / CGFloat(image.height)
        let minimumWidth = max(96, 72 * ratio)
        let maximumWidth = min(3200, max(minimumWidth, (window.screen?.visibleFrame.width ?? 1200) * 0.95))
        let width = min(max(frame.width * factor, minimumWidth), maximumWidth)
        let height = width / ratio
        let x = frame.minX - (width - frame.width) * point.x / max(bounds.width, 1)
        let y = frame.minY - (height - frame.height) * point.y / max(bounds.height, 1)
        window.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
    }
}
