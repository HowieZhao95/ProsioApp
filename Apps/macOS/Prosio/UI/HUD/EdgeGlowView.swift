import SwiftUI

/// Soft, rotating bloom that hugs the edges of a screen. Hosted in a mouse-transparent,
/// non-activating `NSPanel` sized to that screen's full frame — never steals focus.
struct EdgeGlowView: View {
    var state: HUDViewState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cornerRadius: CGFloat { 28 }
    private var edgeInset: CGFloat { 6 }

    private var targetOpacity: Double {
        switch state.phase {
        case .idle: 0
        case .listening: 1
        case .finalizing: 0.55
        case .inserting: 0.55
        case .finished: 0.9
        case .failed: 0.85
        }
    }

    private var fadeAnimation: Animation {
        switch state.phase {
        case .finished, .idle: .easeOut(duration: 0.45)
        default: .easeInOut(duration: 0.35)
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion || state.phase == .idle)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation: Double = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 36) / 36 * 360
            let breathe = 1.0 + Double(state.level) * 0.6

            ZStack {
                layer(index: 0, rotation: rotation, breathe: breathe)
                layer(index: 1, rotation: rotation, breathe: breathe)
                layer(index: 2, rotation: rotation, breathe: breathe)
                layer(index: 3, rotation: rotation, breathe: breathe)
            }
            .padding(edgeInset)
            .opacity(targetOpacity)
            .animation(fadeAnimation, value: state.phase)
        }
        .allowsHitTesting(false)
    }

    private func layer(index: Int, rotation: Double, breathe: Double) -> some View {
        let colors = ProsioPalette.gradient(errorTinted: state.isErrorTinted)
        let baseWidth: CGFloat = 5 + CGFloat(index) * 6
        let width = baseWidth * (index == 0 ? breathe : 1.0 + (breathe - 1.0) * 0.5)
        let blur: CGFloat = 2 + CGFloat(index) * 9

        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                AngularGradient(colors: colors, center: .center, angle: .degrees(rotation + Double(index) * 30)),
                lineWidth: width
            )
            .blur(radius: blur)
            .opacity(index == 0 ? 1.0 : 0.85 - Double(index) * 0.16)
    }
}

#if DEBUG
#Preview("Listening") {
    EdgeGlowView(state: .previewListening)
        .frame(width: 900, height: 560)
        .background(Color.black)
}

#Preview("Failed") {
    EdgeGlowView(state: .previewFailed)
        .frame(width: 900, height: 560)
        .background(Color.black)
}
#endif
