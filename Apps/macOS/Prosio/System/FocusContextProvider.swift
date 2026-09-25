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

/// Frontmost app + caret rect via Accessibility. Owned by mac-system agent.
final class FocusContextProvider: FocusContextProviding {
    /// This runs synchronously on the main thread at dictation start, so a hung target app must
    /// never be able to stall it noticeably. `AXUIElementSetMessagingTimeout` is per-element (it
    /// does NOT propagate from the system-wide element to elements looked up through it), so it
    /// has to be set again on the focused element itself — otherwise those calls fall back to
    /// AX's ~6s default timeout.
    private static let messagingTimeout: Float = 0.06

    func currentContext() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Self.messagingTimeout)

        var isSecure = IsSecureEventInputEnabled()
        var caretRect: CGRect?

        var focusedRef: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        if focusedResult == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)

            if Self.isSecureField(element) {
                isSecure = true
            }
            caretRect = Self.caretRect(for: element)
        }

        return FocusContext(
            bundleID: app?.bundleIdentifier,
            appName: app?.localizedName,
            processID: app?.processIdentifier,
            caretRect: caretRect,
            isSecureInput: isSecure
        )
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(element, kAXRoleAttribute), role == "AXSecureTextField" {
            return true
        }
        if let subrole = stringAttribute(element, kAXSubroleAttribute), subrole == "AXSecureTextField" {
            return true
        }
        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

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
}
