import CoreGraphics
import Foundation

/// Global event tap. It only observes typing, except that the handler may swallow an event
/// (used for Tab while a suggestion is showing) by returning true.
final class KeyMonitor {
    /// Stamped on events we synthesize so we don't react to our own corrections.
    static let injectedMarker: Int64 = 0x5245_5459   // "RETY"

    /// Runs on the main thread. Return true to swallow the event.
    var handler: ((CGEventType, CGEvent) -> Bool)?
    fileprivate var tap: CFMachPort?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyMonitorCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

private func keyMonitorCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    default:
        if event.getIntegerValueField(.eventSourceUserData) != KeyMonitor.injectedMarker {
            if monitor.handler?(type, event) == true { return nil }
        }
    }
    return Unmanaged.passUnretained(event)
}
