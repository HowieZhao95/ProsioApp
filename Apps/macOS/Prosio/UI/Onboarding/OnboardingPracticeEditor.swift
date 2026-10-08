import AppKit
import Observation
import SwiftUI

@Observable
final class OnboardingPracticeEditorState {
    var text = ""
    @ObservationIgnored var selectAllOnUpdate = false
    @ObservationIgnored weak var textView: OnboardingPracticeTextView?
    func focus(selectAll: Bool = false) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        if selectAll { selectAllOnUpdate = true; textView.selectAll(nil) }
    }
}

final class OnboardingPracticeTextView: NSTextView, PracticeTextTarget {
    let practiceIdentifier = UUID().uuidString
    private var capturedRange: NSRange?
    private var capturedText: String?
    var practiceAvailable: Bool { window != nil && isEditable }
    var practiceSelectedText: String? {
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return nil }
        return (string as NSString).substring(with: range)
    }
    func preparePracticeInsertion() {
        capturedRange = selectedRange()
        capturedText = string
    }
    func insertPracticeText(_ text: String) -> Bool {
        guard practiceAvailable, capturedText == string, let range = capturedRange,
              NSMaxRange(range) <= (string as NSString).length else { return false }
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        didChangeText()
        capturedRange = nil
        capturedText = nil
        return true
    }
}

struct OnboardingPracticeEditor: NSViewRepresentable {
    let state: OnboardingPracticeEditorState
    var placeholder: String = "文字会出现在这里"
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = OnboardingPracticeScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let text = OnboardingPracticeTextView()
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.drawsBackground = false
        text.font = NSFont.systemFont(ofSize: 21, weight: .regular)
        text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 24, height: 20)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.minSize = NSSize(width: 0, height: 174)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 174)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.delegate = context.coordinator
        text.setAccessibilityLabel("语音练习区")
        text.string = state.text
        scroll.documentView = text
        state.textView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? OnboardingPracticeTextView else { return }
        if text.string != state.text { text.string = state.text }
        if state.selectAllOnUpdate {
            text.selectAll(nil)
            state.selectAllOnUpdate = false
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: OnboardingPracticeEditorState
        init(_ state: OnboardingPracticeEditorState) { self.state = state }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { state.text = view.string }
        }
    }
}

private final class OnboardingPracticeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView, abs(text.frame.width - contentSize.width) > 0.5 else { return }
        text.setFrameSize(NSSize(width: contentSize.width, height: max(contentSize.height, text.frame.height)))
    }
}
