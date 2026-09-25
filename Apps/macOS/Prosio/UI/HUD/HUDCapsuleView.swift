import SwiftUI

/// Where the capsule should sit, expressed in the *content view's* local top-left coordinate
/// space (i.e. already flipped from AppKit's bottom-left screen coordinates).
struct HUDCapsuleAnchor: Equatable {
    enum EdgeDirection: Equatable { case above, below }

    /// Desired horizontal center, and the Y line the capsule's near edge should touch.
    var point: CGPoint
    /// Whether the capsule sits above (bottom edge = point.y) or below (top edge = point.y) that line.
    var direction: EdgeDirection

    static let zero = HUDCapsuleAnchor(point: .zero, direction: .above)
}

private struct HUDSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Liquid-glass capsule: waveform + live preview while listening, a short status line once
/// the session stops. Hosted in a mouse-transparent, non-activating `NSPanel`.
struct HUDCapsuleView: View {
    var state: HUDViewState
    var anchor: HUDCapsuleAnchor
    var onCopy: () -> Void

    @State private var measuredSize: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            capsuleBody
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: HUDSizeKey.self, value: geo.size)
                    }
                )
                .position(position)
        }
        .onPreferenceChange(HUDSizeKey.self) { measuredSize = $0 }
        .opacity(state.isVisible ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: state.phase)
    }

    private var position: CGPoint {
        let halfHeight = max(measuredSize.height, 40) / 2
        let y = anchor.direction == .above ? anchor.point.y - halfHeight : anchor.point.y + halfHeight
        return CGPoint(x: anchor.point.x, y: y)
    }

    private var displayText: String {
        if let status = state.statusText { return status }
        return state.previewText.isEmpty ? "Listening…" : state.previewText
    }

    private var glassTint: Glass {
        state.isErrorTinted ? Glass.regular.tint(.red.opacity(0.28)) : Glass.regular
    }

    private var capsuleBody: some View {
        HStack(spacing: 10) {
            glyph
            if state.showsWaveform {
                WaveformView(levels: state.levelHistory, errorTinted: state.isErrorTinted)
                    .frame(width: 60, height: 22)
            }
            Text(displayText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(state.showsWaveform ? 2 : 1)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420, alignment: .leading)
            if state.offersCopyAction {
                Button(action: onCopy) {
                    Text("Copy")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 220)
        .glassEffect(glassTint, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .animation(.easeOut(duration: 0.12), value: state.previewText)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state.phase {
        case .listening:
            PulsingDot(color: ProsioPalette.pink)
        case .finalizing, .inserting:
            ProgressView()
                .controlSize(.small)
        case .finished(.pasted), .finished(.accessibility):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .finished(.copiedToClipboard):
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.blue)
        case .finished(.failed):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

private struct PulsingDot: View {
    var color: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 9, height: 9)
            .scaleEffect(pulse ? 1.15 : 0.75)
            .opacity(pulse ? 1.0 : 0.6)
            .onAppear { pulse = true }
            .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: pulse)
    }
}

/// Mirrored rounded bars driven by a rolling level history (oldest first).
struct WaveformView: View {
    var levels: [Float]
    var errorTinted: Bool = false

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let spacing: CGFloat = 1.5
            let count = CGFloat(levels.count)
            let barWidth = max(1.2, (size.width - (count - 1) * spacing) / count)
            let midY = size.height / 2
            let colors = ProsioPalette.gradient(errorTinted: errorTinted)
            let gradient = Gradient(colors: colors)

            for (index, raw) in levels.enumerated() {
                let level = CGFloat(max(0, min(1, raw)))
                let barHeight = max(2, level * size.height)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
        }
        .drawingGroup()
    }
}

#if DEBUG
#Preview("Listening") {
    HUDCapsuleView(state: .previewListening, anchor: HUDCapsuleAnchor(point: CGPoint(x: 300, y: 300), direction: .above)) {}
        .frame(width: 600, height: 400)
        .background(Color.gray.opacity(0.2))
}

#Preview("Finished") {
    HUDCapsuleView(state: .previewFinishedPasted, anchor: HUDCapsuleAnchor(point: CGPoint(x: 300, y: 300), direction: .above)) {}
        .frame(width: 600, height: 400)
        .background(Color.gray.opacity(0.2))
}

#Preview("Failed") {
    HUDCapsuleView(state: .previewFailed, anchor: HUDCapsuleAnchor(point: CGPoint(x: 300, y: 300), direction: .above)) {}
        .frame(width: 600, height: 400)
        .background(Color.gray.opacity(0.2))
}
#endif
