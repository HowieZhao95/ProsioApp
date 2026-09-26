import AppKit
import ProsioCore
import SwiftUI

/// Sums the natural (unclamped) heights of the header, the body's actual content, and the footer
/// — each reports its own height independent of whatever height the card as a whole is currently
/// given, which is what makes self-measurement converge correctly (see `AnswerCardView` below).
private struct AnswerCardIntrinsicHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private extension View {
    /// Reports this view's own rendered height into `AnswerCardIntrinsicHeightKey`, additively
    /// (see `reduce` above) — attach to each independently-sized piece being summed.
    func measuringHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: AnswerCardIntrinsicHeightKey.self, value: geo.size.height)
            }
        )
    }
}

/// The Ask-mode answer card's visible content — header (question + collapsed earlier turns), a
/// Markdown body (streaming, shimmer placeholder, or inline error), and a footer with
/// Insert/Copy/Close. `.regularMaterial` once, 16pt corners, a hairline border and a single soft
/// shadow — no stacked blur.
///
/// Sizing: this view renders at an EXPLICIT `height` (given by `AnswerCardContainerView`, already
/// clamped to 50% of the screen) but continuously measures and reports its OWN natural, unclamped
/// height back via `onIntrinsicHeightChange`, so the container can feed a corrected `height` back
/// on the next render. This is self-measurement, not a parallel hidden clone: the header and
/// footer report their own height regardless of the card's overall height (they're fixed VStack
/// children, not stretched), and the body's content — measured INSIDE the `ScrollView`, via a
/// `.background(GeometryReader …)` on the content itself rather than the `ScrollView` — always
/// lays out at its full natural size regardless of the `ScrollView`'s clipped viewport height.
/// (An earlier version used a second, invisible `opacity(0)` instance positioned far off-screen
/// purely to measure; that clone's `PreferenceKey` never fired in practice — most likely culled by
/// AppKit/SwiftUI as effectively off-screen — leaving `naturalHeight` stuck at 0 and the card
/// visibly clamped to just its header+footer. Measuring the real, on-screen view removes that
/// failure mode entirely.)
struct AnswerCardView: View {
    var answer: AnswerState
    /// Trigger-key label for the footer's "… to follow up" hint (see `TriggerKey.followUpLabel`).
    var askKeyLabel: String
    var height: CGFloat
    var onInsert: () -> Void
    var onCopy: () -> Void
    var onClose: () -> Void
    var onIntrinsicHeightChange: (CGFloat) -> Void = { _ in }

    @State private var userScrolledUp = false
    private let bottomAnchorID = "bottom"
    private let dividerHeight: CGFloat = 2 // two hairline Dividers, not individually measured

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.measuringHeight()
            Divider().opacity(0.5)
            bodyContent
            Divider().opacity(0.5)
            footer.measuringHeight()
        }
        .frame(width: 520, height: height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onPreferenceChange(AnswerCardIntrinsicHeightKey.self) { onIntrinsicHeightChange($0 + dividerHeight) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(earlierQuestions.enumerated()), id: \.offset) { _, question in
                Text(question)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(answer.question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Genuinely EARLIER turns only. Core appends the just-finished Q/A pair to `answer.turns`
    /// once streaming ends, so at that point the last 2 turns ARE `answer.question`/the body
    /// already shown below — dropping them avoids showing the question twice. While still
    /// streaming, `turns` hasn't been appended to yet, so everything in it is genuinely earlier.
    private var earlierQuestions: [String] {
        let earlierTurns: [ComposeTurn]
        if answer.isStreaming {
            earlierTurns = answer.turns
        } else if answer.turns.count >= 2 {
            earlierTurns = answer.turns.dropLast(2).map { $0 }
        } else {
            earlierTurns = []
        }
        return earlierTurns.filter { $0.role == .user }.map(\.text)
    }

    // MARK: - Body

    private var bodyContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                bodyInner
                    .padding(16)
                    // Measured HERE (the content, inside the ScrollView) rather than on the
                    // ScrollView itself: content always lays out at its full natural size
                    // regardless of the ScrollView's own (possibly clamped) viewport height, so
                    // this keeps reporting the true, unclamped body height even while capped.
                    .measuringHeight()
            }
            // Auto-scroll to the newest tokens while streaming, unless the user manually
            // scrolled (a drag anywhere in the scroll view turns this off until the next question).
            .onChange(of: answer.text) { _, _ in
                guard !userScrolledUp, answer.isStreaming else { return }
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            .onChange(of: answer.question) { _, _ in
                userScrolledUp = false
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in userScrolledUp = true })
    }

    private var bodyInner: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = answer.error {
                errorView(error)
            } else if answer.text.isEmpty && answer.isStreaming {
                ShimmerPlaceholder()
            } else {
                MarkdownBody(text: answer.text, onCopyCode: copyCode)
            }
            Color.clear.frame(height: 1).id(bottomAnchorID)
        }
    }

    private func copyCode(_ code: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    /// Plain, factual wording — no "Retry" button/verb, since Ask has no retry affordance yet.
    private func errorView(_ error: ProsioError) -> some View {
        Text(error.hudMessage)
            .font(.system(size: 13))
            .foregroundStyle(Color.red.opacity(0.85))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Insert", action: onInsert)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAct)

            Button("Copy", action: onCopy)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canAct)

            Spacer()

            Text("Esc to close · \(askKeyLabel) to follow up")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private var canAct: Bool {
        !answer.text.isEmpty && !answer.isStreaming && answer.error == nil
    }
}

/// Footer-hint label for "press … to follow up" — P1.1: there's only ever one hotkey (the
/// dictation trigger key, fn by default) and pressing it while the answer card is open starts a
/// follow-up question. Kept local to `UI/Answer` rather than added to
/// `UI/Support/TriggerKeyDisplay.swift`, since this wording ("fn" plain, not "fn (🌐)") is specific
/// to this compact hint.
extension TriggerKey {
    var followUpLabel: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        }
    }
}

// MARK: - Markdown body

/// Splits on fenced code blocks, then splits each prose chunk on blank lines into paragraphs (and
/// lists) — each becomes its own `Text`/row, all spaced 8pt apart. Cheap: plain string splitting,
/// no external Markdown library.
///
/// `AttributedString(markdown:)` with `.full` syntax parses paragraph/list structure into
/// `PresentationIntent` attributes, but a single `SwiftUI.Text` showing that whole `AttributedString`
/// does NOT re-insert paragraph breaks or list bullets when it renders — "…first.\n\nIf your…"
/// visibly collapses to "…first.If your…", and list markers vanish. Splitting into separate `Text`
/// views ourselves (one per paragraph, one per list item) sidesteps that entirely; each individual
/// piece still gets inline markdown (bold, code spans, links) via `.inlineOnlyPreservingWhitespace`,
/// which also preserves single `\n`s WITHIN a paragraph as real line breaks.
private struct MarkdownBody: View {
    var text: String
    var onCopyCode: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlock.parse(text)) { block in
                switch block.kind {
                case .paragraph(let attributed):
                    Text(attributed)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .listItem(let marker, let attributed):
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(attributed)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language, onCopy: onCopyCode)
                }
            }
        }
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(AttributedString)
        case listItem(marker: String, AttributedString)
        case code(String, language: String?)
    }
    let id = UUID()
    let kind: Kind

    private static var inlineOptions: AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return options
    }

    private static func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: inlineOptions)) ?? AttributedString(string)
    }

    /// Alternates prose/code on "```" fences. A trailing, still-unclosed fence (mid-stream) is
    /// simply rendered as a code block with whatever has arrived so far — no flicker, no special
    /// casing needed since `components(separatedBy:)` still yields that last partial segment.
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let parts = text.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 0 {
                blocks.append(contentsOf: parseProse(part))
            } else {
                guard !part.isEmpty else { continue }
                let lines = part.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                var language: String?
                var code = part
                if let first = lines.first {
                    let trimmedFirst = first.trimmingCharacters(in: .whitespaces)
                    if !trimmedFirst.isEmpty, !trimmedFirst.contains(" "), trimmedFirst.count < 20 {
                        language = trimmedFirst
                        code = lines.count > 1 ? String(lines[1]) : ""
                    }
                }
                blocks.append(MarkdownBlock(kind: .code(code, language: language)))
            }
        }
        return blocks
    }

    /// Splits on blank lines (`\n\n+`) into paragraphs; a paragraph whose non-empty lines are ALL
    /// list items (`- `/`* `/`+ ` or `1. `) renders as one row per item instead of one `Text`.
    private static func parseProse(_ text: String) -> [MarkdownBlock] {
        let paragraphs = text.components(separatedBy: "\n\n")
        var blocks: [MarkdownBlock] = []
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let lines = trimmed.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let items = lines.map { listItem(for: $0) }
            if !items.isEmpty, items.allSatisfy({ $0 != nil }) {
                for item in items {
                    guard let (marker, content) = item else { continue }
                    blocks.append(MarkdownBlock(kind: .listItem(marker: marker, inline(content))))
                }
            } else {
                blocks.append(MarkdownBlock(kind: .paragraph(inline(trimmed))))
            }
        }
        return blocks
    }

    /// Strips a bullet ("-"/"*"/"+") or numbered ("1.") list marker from one line, if present.
    private static func listItem(for line: String) -> (marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(bullet) {
                return ("•", String(trimmed.dropFirst(bullet.count)))
            }
        }
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let prefix = trimmed[trimmed.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.count <= 3, prefix.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIndex)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        return ("\(prefix).", String(trimmed[trimmed.index(after: afterDot)...]))
    }
}

private struct CodeBlockView: View {
    var code: String
    var language: String?
    var onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button { onCopy(code) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Shimmer placeholder (until first token)

private struct ShimmerPlaceholder: View {
    @State private var animate = false
    private let barWidths: [CGFloat] = [260, 320, 180]

    var body: some View {
        bars
            .foregroundStyle(Color.primary.opacity(0.12))
            .overlay(shimmerBand)
            .onAppear { animate = true }
            .onDisappear { animate = false }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(barWidths, id: \.self) { width in
                RoundedRectangle(cornerRadius: 4).frame(width: width, height: 10)
            }
        }
    }

    private var shimmerBand: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.35), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.4)
            .offset(x: animate ? geo.size.width * 1.2 : -geo.size.width * 0.6)
            .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: animate)
        }
        .mask(bars)
        .allowsHitTesting(false)
    }
}

#if DEBUG
extension AnswerState {
    static let previewShort = AnswerState(
        question: "What's the capital of Portugal?",
        text: "Lisbon.",
        isStreaming: false
    )
    static let previewStreaming = AnswerState(
        question: "What's a good icebreaker for a standup?",
        text: "Try asking each person to share one thing they're",
        isStreaming: true
    )
    static let previewDoneWithCode = AnswerState(
        question: "How do I center a div with flexbox?",
        text: """
        Use `display: flex` on the parent, then center both axes:

        ```css
        .container {
          display: flex;
          align-items: center;
          justify-content: center;
        }
        ```

        That works for a single child regardless of its size.
        """,
        isStreaming: false
    )
    static let previewLong = AnswerState(
        question: "Give me a thorough overview of how TCP congestion control works.",
        text: """
        TCP congestion control keeps a sender from overwhelming the network. The classic algorithm has four phases:

        1. **Slow start** — the congestion window starts small and doubles every round-trip until it hits a threshold or a loss occurs.
        2. **Congestion avoidance** — growth becomes linear (roughly +1 segment per RTT) instead of exponential.
        3. **Fast retransmit** — three duplicate ACKs trigger an immediate retransmission instead of waiting for a timeout.
        4. **Fast recovery** — the window is halved rather than reset to the slow-start minimum, so throughput recovers faster after an isolated loss.

        Modern stacks mostly use **CUBIC** (Linux default) or **BBR** (used by many CDNs), which model available bandwidth and round-trip time directly instead of relying purely on loss as the congestion signal:

        ```text
        cwnd
         |        ____
         |       /    \\__
         |   ___/         \\___
         |__/                  \\___
         +-------------------------- time
        ```

        BBR in particular tends to achieve higher throughput on lossy or high-bandwidth-delay-product links, since it doesn't back off just because a packet was dropped for an unrelated reason.
        """,
        isStreaming: false
    )
    static let previewError = AnswerState(
        question: "What's the weather in Tokyo right now?",
        text: "",
        isStreaming: false,
        error: .network("timeout")
    )
    static let previewFollowUp = AnswerState(
        question: "What about for a remote team?",
        text: "For remote teams, keep it async-friendly: post the icebreaker in a channel and let people answer whenever they log on, rather than waiting on a live call.",
        isStreaming: false,
        turns: [
            ComposeTurn(role: .user, text: "What's a good icebreaker for a standup?"),
            ComposeTurn(role: .assistant, text: "Try asking each person to share one quick thing."),
            ComposeTurn(role: .user, text: "What about for a remote team?"),
            ComposeTurn(role: .assistant, text: "For remote teams, keep it async-friendly: post the icebreaker in a channel and let people answer whenever they log on, rather than waiting on a live call."),
        ]
    )
}

#Preview("Short answer") {
    AnswerCardView(answer: .previewShort, askKeyLabel: "fn", height: 150, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}

#Preview("Streaming") {
    AnswerCardView(answer: .previewStreaming, askKeyLabel: "fn", height: 190, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}

#Preview("Done with code") {
    AnswerCardView(answer: .previewDoneWithCode, askKeyLabel: "fn", height: 330, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}

#Preview("Long answer (capped, scrolls)") {
    AnswerCardView(answer: .previewLong, askKeyLabel: "fn", height: 420, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}

#Preview("Error") {
    AnswerCardView(answer: .previewError, askKeyLabel: "fn", height: 150, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}

#Preview("Follow-up (no duplicate question)") {
    AnswerCardView(answer: .previewFollowUp, askKeyLabel: "fn", height: 210, onInsert: {}, onCopy: {}, onClose: {})
        .padding(40)
}
#endif
