import AppKit
import Observation
import ProsioCore
import SwiftUI

/// Non-activating overlay for Ask-mode answers (`DictationPhase.answering`). Never key/main — but
/// unlike the capsule's Copy-only exception, this panel's buttons/scrolling must ALWAYS be
/// clickable while it's up, so `ignoresMouseEvents` is simply `false` for as long as it's visible.
/// That's safe because `canBecomeKey`/`canBecomeMain` stay `false` (inherited from `HUDPanel`):
/// AppKit delivers mouse events to a non-key panel without ever making it (or the app) active, so
/// clicking Insert/Copy/Close never steals focus from whatever the user was typing into.
///
/// Owned internally by `HUDController` (not exposed on `AppEnvironment`) so `HUDController`'s own
/// frozen `init(controller:settings:)` doesn't have to change to get a second panel.
final class AnswerCardController {
    private let controller: DictationController
    private let settings: AppSettings

    private let panel = HUDPanel()
    private let hosting: NSHostingView<AnswerCardContainerView>

    private var currentScreen: NSScreen?
    private var dockInset: CGFloat = 0
    private var isVisible = false

    /// Polls at ~20Hz while `.answering` and only touches the hosting view when `AnswerState`
    /// actually changed — this is the "throttle re-render while streaming" requirement: deltas
    /// can arrive far faster than 20Hz, but we only ever push a new SwiftUI value that often.
    private var pollTask: Task<Void, Never>?
    private var lastRendered: AnswerState?

    init(controller: DictationController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings

        panel.ignoresMouseEvents = false

        hosting = NSHostingView(
            rootView: AnswerCardContainerView(
                answer: nil,
                askKeyLabel: settings.askTriggerKey.followUpLabel,
                dockInset: 0,
                onInsert: {},
                onCopy: {},
                onClose: {}
            )
        )
        panel.contentView = hosting

        startObserving()
    }

    // MARK: - Observation

    private func startObserving() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.handlePhaseChange()
                self?.startObserving()
            }
        }
        handlePhaseChange()
    }

    private func handlePhaseChange() {
        if controller.phase == .answering {
            if !isVisible { show() }
            startPolling()
        } else {
            stopPolling()
            hide()
        }
    }

    // MARK: - Show / hide / placement

    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func show() {
        guard let screen = targetScreen() else { return }
        currentScreen = screen
        dockInset = screen.visibleFrame.minY - screen.frame.minY
        panel.setFrame(screen.frame, display: false)
        isVisible = true
        render()
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard isVisible else { return }
        isVisible = false
        lastRendered = nil
        panel.orderOut(nil)
    }

    // MARK: - Polling / render (throttled)

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.renderIfChanged()
                try? await Task.sleep(for: .milliseconds(50)) // ~20Hz
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func renderIfChanged() {
        guard controller.answer != lastRendered else { return }
        lastRendered = controller.answer
        render()
    }

    private func render() {
        hosting.rootView = AnswerCardContainerView(
            answer: controller.answer,
            askKeyLabel: settings.askTriggerKey.followUpLabel,
            dockInset: dockInset,
            onInsert: { [weak self] in self?.insert() },
            onCopy: { [weak self] in self?.copyAnswer() },
            onClose: { [weak self] in self?.dismiss() }
        )
    }

    // MARK: - Actions

    private func insert() {
        Task { @MainActor [weak self] in
            await self?.controller.insertAnswer()
        }
    }

    private func dismiss() {
        controller.dismissAnswer()
    }

    private func copyAnswer() {
        guard let text = controller.answer?.text, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Positions the card bottom-center, just above the capsule (which sits `80pt` above the screen's
/// visible bottom and is `36pt` tall), and sizes it to hug its content — growing while streaming,
/// capped at 50% of the screen height (past that the card's own body scrolls).
///
/// How the sizing works: the one, real `AnswerCardView` measures ITSELF (see its doc comment) and
/// reports its natural, unclamped height via `onIntrinsicHeightChange`; this view clamps that to
/// `min(max(naturalHeight, minCardHeight), maxCardHeight)` and feeds it back in as `height` on the
/// next render. A prior version used a second, invisible (`opacity(0)`, far off-screen) clone
/// purely to measure — its `PreferenceKey` never actually fired in the live app (most likely
/// culled as effectively off-screen), leaving `naturalHeight` stuck at `0` and the card visibly
/// clamped to just its header+footer with an empty body. Self-measuring the real view removes that
/// failure mode: there's nothing to go stale, since the measured view IS the displayed one.
struct AnswerCardContainerView: View {
    var answer: AnswerState?
    var askKeyLabel: String
    var dockInset: CGFloat
    var onInsert: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void

    @State private var naturalHeight: CGFloat = 0

    private let minCardHeight: CGFloat = 96
    /// Capsule's own bottom gap (80) + its height (36) + a little breathing room above it.
    private let bottomGap: CGFloat = 80 + 36 + 12

    var body: some View {
        GeometryReader { geo in
            let maxCardHeight = geo.size.height * 0.5
            if let answer {
                let cardHeight = min(max(naturalHeight, minCardHeight), maxCardHeight)

                // The one, real, on-screen card — it measures ITSELF (header + body's actual
                // content + footer) and reports that back via `onIntrinsicHeightChange`, so the
                // `height` we hand it here converges to the true natural size within a render or
                // two (see AnswerCardView's doc comment for why the previous hidden-clone
                // approach silently failed to measure at all).
                AnswerCardView(
                    answer: answer,
                    askKeyLabel: askKeyLabel,
                    height: cardHeight,
                    onInsert: onInsert,
                    onCopy: onCopy,
                    onClose: onClose,
                    onIntrinsicHeightChange: { naturalHeight = $0 }
                )
                .position(x: geo.size.width / 2, y: geo.size.height - dockInset - bottomGap - cardHeight / 2)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity
                ))
                .animation(.easeOut(duration: 0.22), value: self.answer == nil)
                .animation(.easeOut(duration: 0.15), value: cardHeight)
            }
        }
        .allowsHitTesting(answer != nil)
    }
}

#if DEBUG
private struct AnswerCardContainerPreviewHost: View {
    var answer: AnswerState

    var body: some View {
        AnswerCardContainerView(
            answer: answer,
            askKeyLabel: "Right ⌘",
            dockInset: 0,
            onInsert: {},
            onCopy: {},
            onClose: {}
        )
        .frame(width: 900, height: 700)
        .background(Color.gray.opacity(0.2))
    }
}

#Preview("Short answer — hugs content") {
    AnswerCardContainerPreviewHost(answer: .previewShort)
}

#Preview("Long answer — caps at 50% and scrolls") {
    AnswerCardContainerPreviewHost(answer: .previewLong)
}

/// Sanity check for the fix in this file: appends text on a repeating timer (a `.task` loop, so
/// it's canvas-safe — a plain `Timer` can outlive/leak across Preview reloads) so you can WATCH
/// the card grow smoothly from header+footer-only up to its capped, scrolling height and back
/// down, without running the full app. If this regresses to a fixed-height or empty-body card,
/// the self-measuring path broke again.
private struct GrowingAnswerPreview: View {
    @State private var text = ""
    @State private var isStreaming = true

    private let words = "This is a streaming answer that grows one word at a time so you can watch the card expand smoothly from just the header and footer up to its capped, scrolling height — verifying the self-measuring sizing path end to end without needing to run the full app at all.".split(separator: " ")

    var body: some View {
        AnswerCardContainerView(
            answer: AnswerState(question: "Explain how this card grows while streaming.", text: text, isStreaming: isStreaming),
            askKeyLabel: "Right ⌘",
            dockInset: 0,
            onInsert: {},
            onCopy: {},
            onClose: {}
        )
        .frame(width: 900, height: 700)
        .background(Color.gray.opacity(0.2))
        .task {
            while !Task.isCancelled {
                text = ""
                isStreaming = true
                for word in words {
                    text += (text.isEmpty ? "" : " ") + word
                    try? await Task.sleep(for: .milliseconds(120))
                }
                isStreaming = false
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

#Preview("Growing while streaming (sanity check)") {
    GrowingAnswerPreview()
}
#endif
