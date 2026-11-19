import CoreGraphics
import Foundation
import SpaTypeCore

/// Applies a suggestion: delete what's on screen, switch input source, replay the same physical keys.
///
/// Replaying keystrokes (instead of inserting finished text) lets the real input method do the work,
/// so Korean composition and Japanese kana/kanji conversion behave exactly as if typed by hand.
final class Corrector {
    private let queue = DispatchQueue(label: "spatype.corrector")
    private(set) var isBusy = false

    func apply(_ suggestion: Suggestion, catalog: InputSourceCatalog, completion: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        queue.async {
            let source = CGEventSource(stateID: .privateState)

            for _ in 0..<suggestion.deleteCount {
                Self.press(CGKeyCode(USLayout.delete), shift: false, source: source)
                usleep(1_500)
            }
            usleep(20_000)

            DispatchQueue.main.sync { catalog.select(suggestion.target) }
            usleep(120_000)   // give the input source switch time to settle

            for stroke in suggestion.replay {
                Self.press(CGKeyCode(stroke.keyCode), shift: stroke.shift, source: source)
                usleep(4_000)
            }

            DispatchQueue.main.async {
                self.isBusy = false
                completion()
            }
        }
    }

    private static func press(_ keyCode: CGKeyCode, shift: Bool, source: CGEventSource?) {
        let flags: CGEventFlags = shift ? .maskShift : []
        post(keyCode, down: true, flags: flags, source: source)
        post(keyCode, down: false, flags: flags, source: source)
    }

    private static func post(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: KeyMonitor.injectedMarker)
        event.post(tap: .cghidEventTap)
    }
}
