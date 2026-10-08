import AppKit
import Observation
import QuartzCore
import SwiftUI

@Observable @MainActor
final class PresentationOverlayContent {
    var pointerPressed = false
    var rightClick = false
    var keyLabel = ""
    var keyPressed = false
}

/// Small click-through panels, sharing one lifecycle and Cocoa screen coordinates.
/// No full-screen windows or pointer replacement; disconnected-screen panels are cleared.
@MainActor final class PresentationOverlays: NSObject {
    private let preferences: PresentationPreferences
    private let content = PresentationOverlayContent()
    private var pointerPanel: PresentationPanel?
    private var keyPanel: PresentationPanel?
    var keycapVisible: Bool { keyPanel?.isVisible == true }
    private var displayLink: CADisplayLink?
    private(set) var pointerFrames = 0
    private(set) var pointerMoves = 0
    private(set) var maximumFrameGap: TimeInterval = 0
    private var previousFrameAt: TimeInterval?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var lastPoint = CGPoint.zero
    private var lastMotion: TimeInterval = 0
    private var releasedAt: TimeInterval?
    private var clickPoint = CGPoint.zero
    private var heldButtons: Set<Int> = []

    init(preferences: PresentationPreferences) { self.preferences = preferences; super.init() }

    func setPointerEnabled(_ enabled: Bool) {
        guard enabled != (displayLink != nil) else { return }
        if !enabled { stopPointer(); return }
        let panel = PresentationPanel()
        panel.contentView = NSHostingView(rootView: PointerHalo(content: content, preferences: preferences))
        panel.setFrame(CGRect(x: 0, y: 0, width: 140, height: 140), display: false)
        pointerPanel = panel
        lastPoint = NSEvent.mouseLocation; lastMotion = PresentationClock.now()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.mouse(event) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.mouse(event); return event
        }
        // Screen-driven cadence keeps up with ProMotion displays. Moving only the origin
        // avoids repeatedly resizing/re-laying out the hosted SwiftUI content.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { stopPointer(); return }
        let link = screen.displayLink(target: self, selector: #selector(pointerFrame(_:)))
        let rate = Float(screen.maximumFramesPerSecond > 0 ? min(120, screen.maximumFramesPerSecond) : 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
        previousFrameAt = nil
        updatePointer()
    }

    private func mouse(_ event: NSEvent) {
        let down = event.type == .leftMouseDown || event.type == .rightMouseDown
        let button = event.buttonNumber
        if down {
            heldButtons.insert(button)
            clickPoint = NSEvent.mouseLocation
            content.rightClick = button == 1 || event.modifierFlags.contains(.control)
            releasedAt = nil
        } else {
            heldButtons.remove(button)
            if heldButtons.isEmpty { releasedAt = PresentationClock.now() }
        }
        content.pointerPressed = !heldButtons.isEmpty
        lastMotion = PresentationClock.now()
        updatePointer()
    }

    @objc private func pointerFrame(_ link: CADisplayLink) {
        pointerFrames += 1
        if let previousFrameAt { maximumFrameGap = max(maximumFrameGap, link.timestamp - previousFrameAt) }
        previousFrameAt = link.timestamp
        updatePointer()
    }

    private func updatePointer() {
        guard let panel = pointerPanel else { return }
        let point = NSEvent.mouseLocation
        let now = PresentationClock.now()
        if point != lastPoint { lastMotion = now; lastPoint = point }
        // Heal missed release events (e.g. switching Spaces while dragging).
        if !heldButtons.isEmpty {
            heldButtons = heldButtons.filter { CGEventSource.buttonState(.combinedSessionState, button: $0 == 0 ? .left : .right) }
            if heldButtons.isEmpty { content.pointerPressed = false; releasedAt = now }
        }
        let isClick = content.pointerPressed || releasedAt.map { now - $0 < 0.22 } == true
        let visible = preferences.pointerStyle == .clicksOnly ? isClick : now - lastMotion < 1.5 || isClick
        guard visible else { if panel.isVisible { panel.orderOut(nil) }; return }
        let center = preferences.pointerStyle == .clicksOnly ? clickPoint : point
        guard NSScreen.screens.contains(where: { $0.frame.contains(center) }) else { panel.orderOut(nil); return }
        let origin = CGPoint(x: center.x - 70, y: center.y - 70)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin); pointerMoves += 1 }
        panel.alphaValue = preferences.pointerStyle == .clicksOnly && !content.pointerPressed && isClick
            ? max(0, 1 - (now - (releasedAt ?? now)) / 0.22) : 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func showChord(_ chord: PresentationChord) {
        guard let label = chord.label else { clearKeys(); return }
        content.keyLabel = label; content.keyPressed = chord.isPressed
        if keyPanel == nil {
            let panel = PresentationPanel()
            panel.identifier = NSUserInterfaceItemIdentifier("prosio.presentation.keycap")
            panel.contentView = NSHostingView(rootView: PresentationKeycap(content: content, preferences: preferences))
            keyPanel = panel
        }
        guard let panel = keyPanel,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { clearKeys(); return }
        let frame = screen.visibleFrame
        let width = min(500, frame.width - 32)
        panel.setFrame(CGRect(x: frame.midX - width / 2, y: frame.minY + 30, width: width, height: 72), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func clearKeys() { content.keyLabel = ""; content.keyPressed = false; keyPanel?.orderOut(nil) }
    func clear() { stopPointer(); clearKeys(); keyPanel?.close(); keyPanel = nil }
    private func stopPointer() {
        displayLink?.invalidate(); displayLink = nil
        previousFrameAt = nil
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
        pointerPanel?.orderOut(nil); pointerPanel?.close(); pointerPanel = nil
        heldButtons.removeAll(); content.pointerPressed = false; releasedAt = nil
    }
}

private final class PresentationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }
}

extension PresentationPreferences.Accent {
    var color: Color { switch self { case .blue: .blue; case .orange: .orange; case .purple: .purple } }
    var title: String { switch self { case .blue: "蓝色"; case .orange: "橙色"; case .purple: "紫色" } }
}

struct PointerHalo: View {
    let content: PresentationOverlayContent
    let preferences: PresentationPreferences
    var body: some View {
        Circle()
            .strokeBorder(content.pointerPressed && content.rightClick ? Color.orange : preferences.accent.color,
                          style: StrokeStyle(lineWidth: content.pointerPressed ? 5 : 3, dash: content.pointerPressed && content.rightClick ? [5, 3] : []))
            .background(Circle().fill(preferences.accent.color.opacity(content.pointerPressed ? 0.12 : 0)))
            .frame(width: preferences.resolvedPointerSize, height: preferences.resolvedPointerSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PresentationKeycap: View {
    let content: PresentationOverlayContent
    let preferences: PresentationPreferences
    var body: some View {
        Text(content.keyLabel)
            .font(.system(size: 25, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 22).padding(.vertical, 10)
            .background(content.keyPressed ? preferences.accent.color.opacity(0.95) : Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(content.keyPressed ? 0.8 : 0.3), lineWidth: content.keyPressed ? 2 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
