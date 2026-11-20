import AppKit
import ApplicationServices
import os

/// Finds where the text caret is on screen via the Accessibility API.
enum CaretLocator {
    /// Caret rectangle in Cocoa screen coordinates (origin bottom-left), or nil if unknown.
    static func caretRect() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let element: AXUIElement = copy(systemWide, kAXFocusedUIElementAttribute) else {
            return nil
        }

        let frame = elementFrame(element)

        // 1. Bounds of the character just before the caret (works in Cocoa apps, Safari, recent Chrome).
        //    At the start of the text there is none: use the left edge of the character after it.
        if let rangeValue: AXValue = copy(element, kAXSelectedTextRangeAttribute) {
            var range = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &range) {
                let atStart = range.location <= 0
                var query = CFRange(location: max(range.location - 1, 0), length: 1)
                if let axQuery = AXValueCreate(.cfRange, &query) {
                    var boundsRef: CFTypeRef?
                    let status = AXUIElementCopyParameterizedAttributeValue(
                        element, kAXBoundsForRangeParameterizedAttribute as CFString, axQuery, &boundsRef
                    )
                    if status == .success, let boundsRef, CFGetTypeID(boundsRef) == AXValueGetTypeID() {
                        var rect = CGRect.zero
                        if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect), rect.height > 0 {
                            let x = atStart ? rect.minX : rect.maxX
                            let caret = CGRect(x: x, y: rect.minY, width: 1, height: rect.height)
                            if isPlausible(caret, in: frame) { return toCocoa(caret) }
                            log.debug("caret rect rejected: \(caret.debugDescription, privacy: .public) in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
                        }
                    }
                }
            }
        }

        // 2. Fall back to the focused element itself, if it's a single-line-ish field.
        if let frame, frame.height > 0, frame.height < 120 {
            return toCocoa(frame)
        }
        return nil
    }

    /// Chromium/Electron sometimes report bounds at (0,0), stale, or for the wrong element.
    /// AX coordinates (top-left origin), so compare against screens converted the same way.
    private static func isPlausible(_ caret: CGRect, in frame: CGRect?) -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let onScreen = NSScreen.screens.contains {
            let f = $0.frame
            return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height).intersects(caret)
        }
        guard onScreen else { return false }
        guard let frame, frame.width > 0, frame.height > 0 else { return true }
        return frame.insetBy(dx: -40, dy: -40).contains(caret)
    }

    /// The focused element's frame in AX coordinates, if it reports one.
    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copy(element, kAXPositionAttribute),
              let sizeValue: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
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
