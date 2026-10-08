import AppKit
import ApplicationServices
import Foundation

// Isolated fixture: never reads or types into the user's documents.
func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

let fixtureText = "PROSIO_SANDBOX_FIXTURE"
let marker = "PROSIO_PASTE_PROBE"
let args = CommandLine.arguments
if args.contains("--fixture") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let menu = NSMenu()
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editItem.submenu = editMenu
    menu.addItem(editItem)
    app.mainMenu = menu
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 540, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Prosio isolated distribution test"
    let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 500, height: 100))
    editor.isRichText = false
    editor.string = fixtureText
    window.contentView!.addSubview(editor)
    window.orderBack(nil)
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    emit(["fixturePID": ProcessInfo.processInfo.processIdentifier])
    let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 9 && event.modifierFlags.contains(.command) { editor.paste(nil); return nil }
        return event
    }
    let observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: editor, queue: .main) { _ in
        emit(["pasteReceived": editor.string == marker])
    }
    Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { _ in app.terminate(nil) }
    app.run()
    NotificationCenter.default.removeObserver(observer)
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
} else {
    guard args.count == 4, let pid = Int32(args[1]) else { fatalError("Usage: Probe <fixturePID> <outside-sandbox-file> <mode>") }
    let target = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(target, 2)
    var focus: CFTypeRef?
    let focusError = AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &focus)
    var selected: CFTypeRef?
    var selectedError: Int32 = -1
    if focusError == .success, let focus, CFGetTypeID(focus) == AXUIElementGetTypeID() {
        let element = unsafeBitCast(focus, to: AXUIElement.self)
        selectedError = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected).rawValue
    }
    // Same active session-event tap flags as Prosio's HotkeyMonitor.
    let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    var outsideRead = "allowed"
    do { _ = try String(contentsOfFile: args[2], encoding: .utf8) }
    catch { outsideRead = String(describing: error) }
    var pasteAttempted = false
    // Address events to the disposable fixture PID; do not activate it.
    // This tests CGEvent injection authorization, not foreground placement.
    // Snapshot every pasteboard representation and restore only if nobody changed it.
    if NSRunningApplication(processIdentifier: pid) != nil {
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        } ?? []
        board.clearContents()
        board.setString(marker, forType: .string)
        let ownChange = board.changeCount
        if let source = CGEventSource(stateID: .combinedSessionState),
           let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
           let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.postToPid(pid)
            up.postToPid(pid)
            pasteAttempted = true
            Thread.sleep(forTimeInterval: 0.8)
        }
        if board.changeCount == ownChange {
            board.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(items)
        }
    }
    emit([
        "mode": args[3], "accessibilityTrusted": AXIsProcessTrusted(),
        "listenEventAccess": CGPreflightListenEventAccess(), "postEventAccess": CGPreflightPostEventAccess(),
        "activeEventTapCreated": tap != nil,
        "activeEventTapEnabled": tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
        "focusedElementError": focusError.rawValue, "selectedTextError": selectedError,
        "selectedTextMatchesFixture": (selected as? String) == fixtureText,
        "pasteAttempted": pasteAttempted, "outsideSandboxRead": outsideRead
    ])
    if let tap { CFMachPortInvalidate(tap) }
}
