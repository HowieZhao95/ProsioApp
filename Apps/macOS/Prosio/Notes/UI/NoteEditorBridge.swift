import AppKit
import SwiftUI
import WebKit

struct NoteEditorView: NSViewRepresentable {
    let bridge: NoteEditorBridge
    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

@MainActor final class NoteEditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    struct Snapshot { let text: String; let document: String; let composing: Bool }
    private weak var coordinator: DailyNotesCoordinator?
    private var ready = false
    private var pendingText = ""
    private var pendingDocument = ""
    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "notes")
        let view = NotesWebView(frame: .zero, configuration: configuration)
        view.appearanceChanged = { [weak self] in self?.configure() }
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.setAccessibilityLabel("每日便签 Markdown 编辑器")
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "NotesEditor") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { coordinator?.message = "编辑器资源缺失，请重新构建应用。" }
        return view
    }()
    init(coordinator: DailyNotesCoordinator) { self.coordinator = coordinator }
    func load(text: String, document: String) {
        pendingText = text; pendingDocument = document
        guard ready else { return }
        let args: [String: Any] = ["text": text, "document": document, "source": coordinator?.sourceMode ?? false]
        Task {
            do {
                _ = try await webView.callAsyncJavaScript("await window.notes.load(payload);", arguments: ["payload": args], in: nil, contentWorld: .page)
                configure()
                if webView.window?.isKeyWindow == true { focus() }
            } catch { coordinator?.message = "无法加载便签：\(error.localizedDescription)" }
        }
    }
    func snapshot() async throws -> Snapshot {
        let result = try await webView.callAsyncJavaScript("return window.notes.snapshot();", arguments: [:], in: nil, contentWorld: .page)
        guard let data = result as? [String: Any], let text = data["text"] as? String, let document = data["document"] as? String else { throw NoteStoreError.recoveryUnavailable }
        return Snapshot(text: text, document: document, composing: data["composing"] as? Bool ?? false)
    }
    func configure() {
        guard ready, let coordinator else { return }
        let dark = coordinator.appearance == "dark" || (coordinator.appearance == "system" && webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let args: [String: Any] = ["dark": dark, "fontSize": coordinator.fontSize, "readonly": coordinator.busy]
        webView.callAsyncJavaScript("window.notes.configure(payload);", arguments: ["payload": args], in: nil, in: .page, completionHandler: nil)
    }
    func setReadOnly(_ value: Bool) { configure() }
    func setSource(_ value: Bool) {
        guard ready else { return }
        webView.callAsyncJavaScript("await window.notes.setSource(value);", arguments: ["value": value], in: nil, in: .page, completionHandler: nil)
    }
    func command(_ name: String) {
        guard ready else { return }
        webView.callAsyncJavaScript("await window.notes.command(name);", arguments: ["name": name], in: nil, in: .page, completionHandler: nil)
    }
    func focus() { guard ready else { return }; webView.evaluateJavaScript("window.notes.focus();", completionHandler: nil) }
    func previewDisk() {
        guard let coordinator, let directory = coordinator.directory else { return }
        Task {
            do {
                let text = try await coordinator.store.diskText(coordinator.selectedDay, directory: directory)
                let alert = NSAlert(); alert.messageText = "磁盘版本 · \(coordinator.selectedDay.key)"
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 260)); scroll.hasVerticalScroller = true
                let textView = NSTextView(frame: scroll.bounds); textView.string = text; textView.isEditable = false
                textView.isVerticallyResizable = true; textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                scroll.documentView = textView; alert.accessoryView = scroll; alert.addButton(withTitle: "关闭"); alert.runModal()
            } catch { coordinator.message = error.localizedDescription }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let event = body["event"] as? String, let coordinator else { return }
        switch event {
        case "ready": ready = true; coordinator.editorReady = true; load(text: pendingText, document: pendingDocument)
        case "change": if let text = body["text"] as? String, let document = body["document"] as? String { coordinator.received(text: text, document: document) }
        case "mode":
            guard body["document"] as? String == coordinator.documentID.uuidString else { return }
            coordinator.sourceMode = body["source"] as? Bool ?? false
            let reason = body["reason"] as? String ?? ""; coordinator.unsupported = reason.isEmpty ? nil : reason
        case "command": if body["name"] as? String == "save" { coordinator.retry() } else if body["name"] as? String == "hide" { coordinator.hide() }
        case "error": coordinator.message = body["message"] as? String
        case "warning": coordinator.unsupported = body["message"] as? String
        case "openLink": if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url, url.isFileURL else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { coordinator?.message = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; coordinator?.editorReady = false
        coordinator?.message = "编辑器意外关闭，正在恢复已保留内容。"
        pendingText = coordinator?.text ?? pendingText; pendingDocument = coordinator?.documentID.uuidString ?? pendingDocument
        webView.reload()
    }
}

@MainActor private final class NotesWebView: WKWebView {
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}
