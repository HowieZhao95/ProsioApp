import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import ProsioCore

/// Converts an Accessibility-API rect (top-left origin, global screen space) into AppKit's
/// bottom-left origin global space. Pure/testable; kept separate from AX plumbing.
enum AXCoordinateConverter {
    static func appKitRect(fromAXRect axRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryScreenHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }
}

/// Frontmost app + caret rect + (P1) window title / selected text / browser URL, via
/// Accessibility. Owned by mac-system agent.
final class FocusContextProvider: FocusContextProviding {
    /// This runs synchronously on the main thread at dictation start, so a hung target app must
    /// never be able to stall it noticeably. `AXUIElementSetMessagingTimeout` is per-element (it
    /// does NOT propagate from one element to elements looked up through it), so it has to be set
    /// again on *every* element this file touches — see `configured(_:)`.
    private static let messagingTimeout: Float = 0.06
    /// Hard wall-clock budget for the whole `currentContext()` call. Checked between steps so a
    /// slow/hung app can make us skip the *rest* of the optional (P1) fields rather than exceed
    /// this — `bundleID`/`appName`/`processID` are free (no AX calls) and always returned.
    private static let totalBudget: TimeInterval = 0.08
    private static let selectedTextMaxLength = 20_000

    /// Bundle ids of browsers we look up `url` for. (No clipboard/⌘C fallback in this pass —
    /// AX-only; see TODO(P1.1) below for apps/browsers this doesn't cover.)
    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "org.mozilla.firefox"
    ]

    func currentContext() -> FocusContext {
        let startTime = Date()
        let deadline = startTime.addingTimeInterval(Self.totalBudget)
        let app = NSWorkspace.shared.frontmostApplication

        var isSecure = IsSecureEventInputEnabled()
        var caretRect: CGRect?
        var windowTitle: String?
        var selectedText: String?
        var url: URL?

        // If Prosio itself is frontmost (a Settings/onboarding window, or the HUD/answer panel
        // somehow becoming key), there's no meaningful "focus context" to capture — and probing
        // our own AX tree while our own non-activating panels are around risks the very
        // system-wide-query confusion this method exists to avoid. Skip AX entirely.
        let isProsioFrontmost = app?.bundleIdentifier == Bundle.main.bundleIdentifier
        if !isProsioFrontmost, let element = Self.resolveFocusedElement(frontmostApp: app) {
            if Self.isSecureField(element) {
                isSecure = true
            }
            caretRect = Self.caretRect(for: element)

            if !isSecure, Date() < deadline {
                selectedText = Self.selectedText(for: element)
            }

            let window: AXUIElement? = Date() < deadline ? Self.window(for: element) : nil

            if let window, Date() < deadline {
                windowTitle = Self.stringAttribute(window, kAXTitleAttribute)
            }

            if let bundleID = app?.bundleIdentifier, Self.browserBundleIDs.contains(bundleID), Date() < deadline {
                url = Self.browserURL(focusedElement: element, window: window, deadline: deadline)
            }
        }

        let elapsedMs = Date().timeIntervalSince(startTime) * 1000
        // No text content logged — just counts, per the mac-system logging convention.
        ProsioLog.focus.info("focus context: app=\(app?.bundleIdentifier ?? "nil", privacy: .public) sel=\(selectedText?.count ?? 0, privacy: .public) chars in \(elapsedMs, privacy: .public)ms")

        return FocusContext(
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            processID: app?.processIdentifier,
            caretRect: caretRect,
            isSecureInput: isSecure,
            windowTitle: windowTitle,
            url: url,
            selectedText: selectedText
        )
    }

    // MARK: - Focused element resolution

    /// Resolves the currently focused AX element. The system-wide element
    /// (`AXUIElementCreateSystemWide()` + `kAXFocusedUIElementAttribute`) can fail with
    /// `kAXErrorCannotComplete` when some other non-activating panel/system dialog is around
    /// (observed live: a system dialog confused the system-wide query even though the actual
    /// frontmost app's own focused element was perfectly readable) — so the app-scoped element
    /// (`AXUIElementCreateApplication(pid)`) is tried FIRST, and system-wide is only the fallback.
    private static func resolveFocusedElement(frontmostApp: NSRunningApplication?) -> AXUIElement? {
        if let pid = frontmostApp?.processIdentifier {
            let appElement = configured(AXUIElementCreateApplication(pid))
            if let element = elementAttribute(appElement, kAXFocusedUIElementAttribute) {
                return element
            }
        }

        let systemWide = configured(AXUIElementCreateSystemWide())
        return elementAttribute(systemWide, kAXFocusedUIElementAttribute)
    }

    // MARK: - Element helpers

    /// Every `AXUIElement` this file hands out goes through here first, so the short messaging
    /// timeout always applies (see `messagingTimeout`'s doc comment — it doesn't propagate).
    private static func configured(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let ref = attribute(element, name), CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return configured(unsafeDowncast(ref, to: AXUIElement.self))
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func roleAttribute(_ element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute)
    }

    private static func urlAttribute(_ element: AXUIElement, _ name: String) -> URL? {
        guard let ref = attribute(element, name) else { return nil }
        if let url = ref as? URL { return url }
        if let string = ref as? String { return URL(string: string) }
        return nil
    }

    // MARK: - Secure input / selected text

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        if roleAttribute(element) == "AXSecureTextField" { return true }
        if stringAttribute(element, kAXSubroleAttribute) == "AXSecureTextField" { return true }
        return false
    }

    /// nil when empty/whitespace-only, or over `selectedTextMaxLength` — never truncated, since a
    /// truncated selection would be actively misleading as Edit-mode/Ask context.
    private static func selectedText(for element: AXUIElement) -> String? {
        if let text = stringAttribute(element, kAXSelectedTextAttribute), isUsableSelection(text) {
            return text
        }
        // Some Electron/Chromium editors don't support (or return empty for) kAXSelectedTextAttribute
        // even with a real selection; fall back to reading the string content for the selected range.
        if let text = selectedTextViaRange(element), isUsableSelection(text) {
            return text
        }
        return nil
    }

    private static func isUsableSelection(_ text: String) -> Bool {
        text.count <= selectedTextMaxLength && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func selectedTextViaRange(_ element: AXUIElement) -> String? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(rangeRef, to: AXValue.self)

        var stringRef: AnyObject?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringRef
        )
        guard result == .success else { return nil }
        return stringRef as? String
    }

    // MARK: - Window title

    private static func window(for element: AXUIElement) -> AXUIElement? {
        elementAttribute(element, kAXWindowAttribute)
    }

    // MARK: - Caret rect (unchanged from the P0 pass)

    private static func caretRect(for element: AXUIElement) -> CGRect? {
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeDowncast(rangeRef, to: AXValue.self)

        var boundsRef: AnyObject?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsRef
        )
        guard boundsResult == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() else {
            return nil
        }
        let boundsValue = unsafeDowncast(boundsRef, to: AXValue.self)

        var axRect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &axRect) else { return nil }

        // Ignore zero-size and absurdly large rects (bad readings from some apps' AX trees).
        guard axRect.width.isFinite, axRect.height.isFinite,
              axRect.width >= 0, axRect.height >= 0,
              axRect.width < 10_000, axRect.height < 10_000,
              !(axRect.origin.x == 0 && axRect.origin.y == 0 && axRect.width == 0 && axRect.height == 0) else {
            return nil
        }

        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else { return nil }
        return AXCoordinateConverter.appKitRect(fromAXRect: axRect, primaryScreenHeight: primaryScreenHeight)
    }

    // MARK: - Browser URL (P1)

    /// TODO(P1.1): apps that don't expose an AXWebArea/kAXURLAttribute/kAXDocumentAttribute (some
    /// Electron/Chromium embeds, non-browser apps with an embedded web view) get no `url` in this
    /// pass — a clipboard/⌘C-based fallback was explicitly deferred, not implemented here.
    private static func browserURL(focusedElement: AXUIElement, window: AXUIElement?, deadline: Date) -> URL? {
        if let webArea = ancestorWebArea(from: focusedElement, deadline: deadline),
           let url = urlAttribute(webArea, kAXURLAttribute) {
            return url
        }
        if let window, Date() < deadline,
           let webArea = descendantWebArea(in: window, maxDepth: 4, maxVisited: 40, deadline: deadline),
           let url = urlAttribute(webArea, kAXURLAttribute) {
            return url
        }
        if let window, Date() < deadline, let url = urlAttribute(window, kAXDocumentAttribute) {
            return url
        }
        return nil
    }

    /// Walks up from the focused element (bounded: browser AX trees are shallow, this is generous)
    /// looking for the AXWebArea that contains it.
    private static func ancestorWebArea(from element: AXUIElement, deadline: Date) -> AXUIElement? {
        var current = element
        for _ in 0..<8 {
            if Date() >= deadline { return nil }
            if roleAttribute(current) == "AXWebArea" { return current }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { return nil }
            current = parent
        }
        return nil
    }

    /// Shallow, bounded search from the window (e.g. when focus is on the toolbar/address bar,
    /// not inside the page) for an AXWebArea.
    private static func descendantWebArea(in root: AXUIElement, maxDepth: Int, maxVisited: Int, deadline: Date) -> AXUIElement? {
        var visited = 0

        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            visited += 1
            guard visited <= maxVisited, depth <= maxDepth, Date() < deadline else { return nil }
            if roleAttribute(element) == "AXWebArea" { return element }
            guard let childrenRef = attribute(element, kAXChildrenAttribute), let children = childrenRef as? [AXUIElement] else {
                return nil
            }
            for child in children {
                if Date() >= deadline { return nil }
                if let found = search(configured(child), depth: depth + 1) {
                    return found
                }
            }
            return nil
        }

        return search(root, depth: 0)
    }
}
