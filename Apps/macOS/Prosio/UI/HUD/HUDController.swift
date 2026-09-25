import AppKit
import Observation
import ProsioCore
import SwiftUI

/// Non-activating overlay: Apple-Intelligence-style edge glow + glass capsule with waveform and
/// live preview. Observes `controller` and shows/hides itself. Owned by mac-ui agent. INIT SIGNATURE FROZEN.
///
/// Two borderless `NSPanel`s (never key, never main, mouse-transparent) render the edge glow and
/// the capsule. Both are driven purely by `HUDViewState`, a plain value snapshot of the
/// controller — that's what makes `showcase()` possible without touching the real session.
final class HUDController {
    private let controller: DictationController
    private let settings: AppSettings

    private let edgeGlowPanel = HUDPanel()
    private let capsulePanel = HUDPanel()
    private let edgeHosting: NSHostingView<EdgeGlowView>
    private let capsuleHosting: NSHostingView<HUDCapsuleView>

    private var state = HUDViewState()
    private var currentScreen: NSScreen?
    private var hideTask: Task<Void, Never>?

    #if DEBUG
    private var isShowcasing = false
    private var showcaseTask: Task<Void, Never>?
    #endif

    init(controller: DictationController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings

        edgeHosting = NSHostingView(rootView: EdgeGlowView(state: HUDViewState()))
        capsuleHosting = NSHostingView(rootView: HUDCapsuleView(state: HUDViewState(), anchor: .zero, onCopy: {}))

        edgeGlowPanel.contentView = edgeHosting
        capsulePanel.contentView = capsuleHosting

        // Now that all stored properties are set, wire up the self-capturing bits and start observing.
        renderHostingViews()
        startObserving()

        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ProsioShowcaseOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showcase()
            }
        }
        #endif
    }

    // MARK: - Observation

    private func startObserving() {
        withObservationTracking {
            syncFromController()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.startObserving()
            }
        }
    }

    private func syncFromController() {
        #if DEBUG
        guard !isShowcasing else { return }
        #endif
        let newState = HUDViewState(
            phase: HUDViewState.Phase(controller.phase),
            previewText: controller.previewText,
            levelHistory: controller.levelHistory,
            level: controller.level,
            caretRect: controller.context?.caretRect
        )
        apply(newState)
    }

    // MARK: - State application

    private func apply(_ newState: HUDViewState) {
        guard newState != state else { return }
        state = newState
        if state.phase != .idle {
            ensurePanelsPositioned()
        }
        renderHostingViews()
        handleVisibility()
    }

    private func renderHostingViews() {
        let anchor: HUDCapsuleAnchor
        if let screen = currentScreen ?? targetScreen() {
            anchor = capsuleAnchor(on: screen)
        } else {
            anchor = .zero
        }
        edgeHosting.rootView = EdgeGlowView(state: state)
        capsuleHosting.rootView = HUDCapsuleView(state: state, anchor: anchor) { [weak self] in
            self?.copyPreviewToPasteboard()
        }
        capsulePanel.ignoresMouseEvents = !state.offersCopyAction
    }

    private func handleVisibility() {
        switch state.phase {
        case .idle:
            hideImmediately()
        case .listening, .finalizing, .inserting:
            show()
        case .finished:
            show()
            scheduleHide(after: 1.2)
        case .failed:
            show()
            scheduleHide(after: 3.0)
        }
    }

    // MARK: - Panel placement

    /// Picks the screen containing the caret; falls back to the screen under the mouse, then main.
    private func targetScreen() -> NSScreen? {
        if let rect = state.caretRect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func ensurePanelsPositioned() {
        guard let screen = targetScreen() else { return }
        guard screen != currentScreen else { return }
        currentScreen = screen
        edgeGlowPanel.setFrame(screen.frame, display: false)
        capsulePanel.setFrame(screen.frame, display: false)
    }

    /// Computes the capsule's anchor in the panel's local (top-left origin) coordinate space,
    /// just above the caret when known and on-screen, flipping below when too close to the top,
    /// else bottom-center of the visible frame.
    private func capsuleAnchor(on screen: NSScreen) -> HUDCapsuleAnchor {
        let gap: CGFloat = 14
        if let rect = state.caretRect, screen.frame.intersects(rect) {
            let localX = rect.midX - screen.frame.minX
            let spaceAbove = screen.frame.maxY - rect.maxY
            let placeAbove = spaceAbove > 160
            let appKitEdgeY = placeAbove ? rect.maxY + gap : rect.minY - gap
            let topLeftY = screen.frame.height - (appKitEdgeY - screen.frame.minY)
            return HUDCapsuleAnchor(point: CGPoint(x: localX, y: topLeftY), direction: placeAbove ? .above : .below)
        }
        let visible = screen.visibleFrame
        let localX = visible.midX - screen.frame.minX
        let appKitEdgeY = visible.minY + 90
        let topLeftY = screen.frame.height - (appKitEdgeY - screen.frame.minY)
        return HUDCapsuleAnchor(point: CGPoint(x: localX, y: topLeftY), direction: .above)
    }

    // MARK: - Show / hide

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        if !edgeGlowPanel.isVisible { edgeGlowPanel.orderFrontRegardless() }
        if !capsulePanel.isVisible { capsulePanel.orderFrontRegardless() }
    }

    private func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
        edgeGlowPanel.orderOut(nil)
        capsulePanel.orderOut(nil)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hideImmediately()
        }
    }

    // MARK: - Copy affordance

    private func copyPreviewToPasteboard() {
        guard !state.previewText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(state.previewText, forType: .string)
    }

    // MARK: - Showcase (DEBUG only)

    #if DEBUG
    /// Cycles fake states — listening / finalizing / finished(pasted) / finished(copiedToClipboard) /
    /// failed — without touching the real `DictationController`. Wired to a DEBUG menu command by
    /// mac-system, and to the `-ProsioShowcaseOnLaunch YES` launch argument above.
    func showcase() {
        showcaseTask?.cancel()
        isShowcasing = true

        showcaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let waveform = (0..<DictationController.levelHistoryLength).map { i in
                Float(0.2 + 0.6 * abs(sin(Double(i) * 0.35)))
            }
            let growingLines = [
                "So let's meet on",
                "So let's meet on Wednesday —",
                "So let's meet on Wednesday — no, Thursday at 3pm…",
                "So let's meet on Wednesday — no, Thursday at 3pm… 顺便把上周的会议纪要也发一下 please",
            ]
            let finalText = growingLines.last!

            for line in growingLines {
                if Task.isCancelled { return }
                self.apply(HUDViewState(phase: .listening, previewText: line, levelHistory: waveform, level: Float.random(in: 0.35...0.9)))
                try? await Task.sleep(for: .milliseconds(550))
            }

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .finalizing, previewText: finalText, levelHistory: waveform.map { $0 * 0.25 }, level: 0.08))
            try? await Task.sleep(for: .seconds(1.1))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .finished(.pasted), previewText: finalText))
            try? await Task.sleep(for: .seconds(1.8))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            try? await Task.sleep(for: .milliseconds(500))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .listening, previewText: finalText, levelHistory: waveform, level: 0.7))
            try? await Task.sleep(for: .seconds(1))
            self.apply(HUDViewState(phase: .finalizing, previewText: finalText, levelHistory: waveform.map { $0 * 0.2 }, level: 0.05))
            try? await Task.sleep(for: .seconds(1))
            self.apply(HUDViewState(phase: .finished(.copiedToClipboard), previewText: finalText))
            try? await Task.sleep(for: .seconds(1.8))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            try? await Task.sleep(for: .milliseconds(500))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .failed(ProsioError.network("request timed out").hudMessage), previewText: "So let's meet on Wednesday"))
            try? await Task.sleep(for: .seconds(3))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            self.isShowcasing = false
            self.startObserving()
        }
    }
    #endif
}
