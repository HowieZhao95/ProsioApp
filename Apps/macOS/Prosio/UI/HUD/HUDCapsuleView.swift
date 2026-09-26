import SwiftUI

/// Minimal, native-feeling pill: a small waveform + live preview while listening, a short status
/// glyph once the session stops. Hosted in a mouse-transparent, non-activating `NSPanel` sized to
/// the whole target screen; this view places the pill itself with a plain `GeometryReader` +
/// `.position()` (bottom-center, `dockInset + 80pt` above the screen's physical bottom edge) — no
/// AppKit-side frame math needed, and the surrounding area is untouched `Color.clear` so only the
/// pill's own small region ever actually draws.
///
/// Deliberately cheap to render: no blur layers. The only per-tick change is a handful of
/// `Capsule` heights (the waveform) while listening — the waveform itself is the recording cue —
/// plus, while `.finalizing`/`.inserting`, a single small `ShimmerText` gradient-mask animation
/// scoped to that view's own lifecycle, so it stops the moment the phase moves on or the panel is
/// hidden.
struct HUDCapsuleView: View {
    var state: HUDViewState
    var dockInset: CGFloat
    var onCopy: () -> Void

    private let pillHeight: CGFloat = 36
    private let maxTextWidth: CGFloat = 360
    private let bottomGap: CGFloat = 80

    var body: some View {
        GeometryReader { geo in
            content
                .fixedSize()
                .position(x: geo.size.width / 2, y: geo.size.height - dockInset - bottomGap - pillHeight / 2)
        }
        .allowsHitTesting(state.offersCopyAction)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .listening:
                MiniWaveform(levelHistory: state.levelHistory)
                if !state.previewText.isEmpty {
                    previewText
                }
            case .finalizing, .inserting:
                if state.previewText.isEmpty {
                    ShimmerText(text: "Processing…")
                } else {
                    ShimmerText(text: state.previewText)
                        .frame(maxWidth: maxTextWidth, alignment: .leading)
                }
            case .finished(.pasted), .finished(.accessibility):
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            case .finished(.copiedToClipboard):
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                statusText
            case .finished(.failed), .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(errorTint)
                statusText
                if state.offersCopyAction {
                    copyButton
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: pillHeight)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.18), value: state.phase)
    }

    private var previewText: some View {
        Text(state.previewText)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: maxTextWidth, alignment: .leading)
            .transition(.opacity)
    }

    private var statusText: some View {
        Text(state.statusText ?? "")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(errorTint == .clear ? Color.secondary : errorTint)
            .lineLimit(1)
    }

    private var errorTint: Color {
        state.isErrorTinted ? Color.red.opacity(0.85) : .clear
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            Text("Copy")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
    }
}

/// 8 thin rounded bars driven by the tail of the rolling level history — this IS the recording
/// cue while `.listening` (it moves with the voice; no separate red dot needed), with a subtly
/// brighter tint than plain secondary text to read as "live". Cheap on purpose: fixed bar
/// count/width, no shadows, no blur — only each bar's height is animated.
private struct MiniWaveform: View {
    var levelHistory: [Float]

    private let barCount = 8
    private let barWidth: CGFloat = 2.5
    private let spacing: CGFloat = 2.5
    private let maxHeight: CGFloat = 16
    private let minHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(0.95))
                    .frame(width: barWidth, height: height(for: index))
            }
        }
        .frame(width: CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing, height: maxHeight)
        .animation(.easeOut(duration: 0.12), value: levelHistory)
    }

    private func height(for index: Int) -> CGFloat {
        let recent = levelHistory.suffix(barCount)
        guard recent.count == barCount else { return minHeight }
        let level = CGFloat(max(0, min(1, recent[recent.index(recent.startIndex, offsetBy: index)])))
        return minHeight + level * (maxHeight - minHeight)
    }
}

/// A soft highlight band sweeping across the text, masked to the text's own glyphs — the
/// "processing" cue for `.finalizing`/`.inserting`, and for the "Processing…" label when there's
/// no on-device transcript yet. A single gradient + one `repeatForever` offset animation, scoped
/// to this view's own lifecycle (`.onAppear`/`.onDisappear`) so it stops the moment the phase
/// moves on or the panel is hidden — no waveform, no dots, nothing else drawn.
private struct ShimmerText: View {
    var text: String

    @State private var animate = false

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .overlay(shimmerBand)
            .onAppear { animate = true }
            .onDisappear { animate = false }
    }

    private var shimmerBand: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.5), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.5)
            .offset(x: animate ? geo.size.width * 1.25 : -geo.size.width * 0.75)
            .animation(.linear(duration: 1.3).repeatForever(autoreverses: false), value: animate)
        }
        .mask(
            Text(text)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.head)
        )
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Listening") {
    HUDCapsuleView(state: .previewListening, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Finalizing (text)") {
    HUDCapsuleView(state: .previewFinalizing, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Processing (no text)") {
    HUDCapsuleView(state: .previewProcessingNoText, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("No text yet") {
    HUDCapsuleView(state: HUDViewState(phase: .listening, previewText: "", levelHistory: HUDViewState.previewListening.levelHistory, level: 0.5), dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Finished") {
    HUDCapsuleView(state: .previewFinishedPasted, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Copied") {
    HUDCapsuleView(state: .previewFinishedCopied, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}

#Preview("Failed") {
    HUDCapsuleView(state: .previewFailed, dockInset: 0, onCopy: {})
        .padding(40)
        .background(Color.gray.opacity(0.2))
}
#endif
