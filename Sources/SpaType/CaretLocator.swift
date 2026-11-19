import AppKit
import ApplicationServices

/// Finds where the text caret is on screen via the Accessibility API.
enum CaretLocator {
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left), or nil if unknown.
    static func caretRect() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let element: AXUIElement = copy(systemWide, kAXFocusedUIElementAttribute) else {
            return nil
        }

        // 1. Bounds of the character just before the caret (works in Cocoa apps, Safari, recent Chrome).
        if let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                var query = CFRange(location: max(range.location - 1, 0), length: range.location > 0 ? 1 : 0)
                if let axQuery = AXValueCreate(.cfRange, &query) {
                    var boundsRef: CFTypeRef?
                    let status = AXUIElementCopyParameterizedAttributeValue(
                        element, kAXBoundsForRangeParameterizedAttribute as CFString, axQuery, &boundsRef
                    )
                    if status == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                        var rect = CGRect.zero
                        if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.height > 0 {
                            let caret = CGRect(x: rect.maxX, y: rect.minY, width: 1, height: rect.height)
                            return toCocoa(caret)
                        }
                    }
                }
            }
        }

        // 2. Fall back to the focused element itself, if it's a single-line-ish field.
        if let positionValue: AXValue = copy(element, kAXPositionAttribute),
           let sizeValue: AXValue = copy(element, kAXSizeAttribute) {
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue, .cgPoint, &position),
               AXValueGetValue(sizeValue, .cgSize, &size),
               size.height > 0, size.height < 120 {
                return toCocoa(CGRect(origin: position, size: size))
            }
        }
        return nil
    }

    /// Electron/Chromium apps only build their accessibility tree when asked to.
    static func enableAccessibility(for pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? T
    }

    /// AX uses top-left origin on the primary screen; Cocoa uses bottom-left.
    private static func toCocoa(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
