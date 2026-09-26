import AppKit
import Observation
import ProsioCore
import SwiftUI

/// Non-activating overlay: a small, minimal pill with a waveform and live preview, bottom-center
/// of the active screen. Observes `controller` and shows/hides itself. Owned by mac-ui agent.
/// INIT SIGNATURE FROZEN.
///
/// A single borderless `NSPanel` (never key, never main, mouse-transparent except for the brief
/// Copy affordance) renders the capsule, driven purely by `HUDViewState` — that's what makes
/// `showcase()` possible without touching the real session.
///
/// The panel covers the target screen's full frame (so the capsule can be placed with plain
/// SwiftUI layout — `.position()` inside a `GeometryReader` — instead of AppKit-side frame math
/// that has to race the SwiftUI layout pass). This is NOT the old edge-glow panel: there is no
/// per-frame drawing over that area — it's just an invisible, mostly-`Color.clear` layout
/// container, and only the small capsule region ever actually redraws. Perf-critical: the panel
/// is ordered OUT (not just faded) whenever idle, so nothing renders or animates at rest, and it
/// is only ever resized when the target screen itself changes (essentially never).
final class HUDController {
    private let controller: DictationController
    private let settings: AppSettings

    private let capsulePanel = HUDPanel()
    private let capsuleHosting: NSHostingView<HUDCapsuleView>

    private var state = HUDViewState()
    private var currentScreen: NSScreen?
    private var dockInset: CGFloat = 0
    private var hideTask: Task<Void, Never>?

    #if DEBUG
    private var isShowcasing = false
    private var showcaseTask: Task<Void, Never>?
    #endif

    init(controller: DictationController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings

        capsuleHosting = NSHostingView(rootView: HUDCapsuleView(state: HUDViewState(), dockInset: 0, onCopy: {}))
        capsulePanel.contentView = capsuleHosting
        layoutForScreen()

        // Now that all stored properties are set, wire up the self-capturing bits and start observing.
        renderHostingView()
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
            level: controller.level
        )
        apply(newState)
    }

    // MARK: - State application

    private func apply(_ newState: HUDViewState) {
        guard newState != state else { return }
        state = newState
        renderHostingView()
        handleVisibility()
    }

    private func renderHostingView() {
        capsuleHosting.rootView = HUDCapsuleView(
            state: state,
            dockInset: dockInset,
            onCopy: { [weak self] in self?.copyPreviewToPasteboard() }
        )
        capsulePanel.ignoresMouseEvents = !state.offersCopyAction
    }

    private func handleVisibility() {
        switch state.phase {
        case .idle:
            hideImmediately()
        case .listening, .finalizing, .inserting:
            show()
        case .finished(.pasted), .finished(.accessibility):
            show()
            scheduleHide(after: 0.7)
        case .finished(.copiedToClipboard):
            show()
            scheduleHide(after: 1.5)
        case .finished(.failed):
            show()
            scheduleHide(after: 2.5)
        case .failed:
            show()
            scheduleHide(after: 2.5)
        }
    }

    // MARK: - Panel placement

    /// Picks the screen under the mouse, falling back to main. (No caret-following — the capsule
    /// is always bottom-center, which keeps this cheap and steady.)
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Only touches AppKit (a `setFrame`) when the target screen actually changed — essentially
    /// never in practice (single-display machines never call this after the first time).
    private func layoutForScreen() {
        guard let screen = targetScreen(), screen != currentScreen else { return }
        currentScreen = screen
        dockInset = screen.visibleFrame.minY - screen.frame.minY
        capsulePanel.setFrame(screen.frame, display: false)
        renderHostingView()
    }

    // MARK: - Show / hide

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        layoutForScreen()
        if !capsulePanel.isVisible { capsulePanel.orderFrontRegardless() }
    }

    private func hideImmediately() {
        hideTask?.cancel()
        hideTask = nil
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

            // Toggle mode: mic closes immediately, but the cloud takes ~2-4s to come back with
            // polished text — show the "Processing…" wait first (no on-device text yet), then the
            // on-device preview arriving mid-wait, dimmed, before the final insert.
            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .finalizing, previewText: "", level: 0))
            try? await Task.sleep(for: .seconds(1.4))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .finalizing, previewText: finalText, level: 0))
            try? await Task.sleep(for: .seconds(1.6))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .inserting, previewText: finalText, level: 0))
            try? await Task.sleep(for: .milliseconds(300))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .finished(.pasted), previewText: finalText))
            try? await Task.sleep(for: .seconds(1.2))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            try? await Task.sleep(for: .milliseconds(500))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .listening, previewText: finalText, levelHistory: waveform, level: 0.7))
            try? await Task.sleep(for: .seconds(1))
            self.apply(HUDViewState(phase: .finalizing, previewText: finalText, level: 0))
            try? await Task.sleep(for: .seconds(1.5))
            self.apply(HUDViewState(phase: .finished(.copiedToClipboard), previewText: finalText))
            try? await Task.sleep(for: .seconds(2))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            try? await Task.sleep(for: .milliseconds(500))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .failed(ProsioError.network("request timed out").hudMessage), previewText: "So let's meet on Wednesday"))
            try? await Task.sleep(for: .seconds(2.5))

            if Task.isCancelled { return }
            self.apply(HUDViewState(phase: .idle))
            self.isShowcasing = false
            self.startObserving()
        }
    }
    #endif
}
