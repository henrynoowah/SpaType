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

            self.switchInputSource(to: suggestion.target, catalog: catalog)

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

    /// Input sources already switched to once in this session; the first switch to an input method
    /// (Korean, Japanese) is slow because the IME has to come up before it handles keys.
    private var warmedUp: Set<String> = []

    /// Selects `target` and blocks (on the corrector queue) until the switch has actually happened,
    /// so the replayed keys aren't typed through the old layout.
    private func switchInputSource(to target: SourceDescriptor, catalog: InputSourceCatalog) {
        func isCurrent() -> Bool { DispatchQueue.main.sync { catalog.current?.id == target.id } }

        for attempt in 0..<2 {
            DispatchQueue.main.sync { catalog.select(target) }
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline, !isCurrent() { usleep(15_000) }
            if isCurrent() { break }
            if attempt == 0 { usleep(50_000) }   // known TIS flakiness with CJK sources: select again
        }

        // The system reports the new source before the frontmost app's text input has picked it up.
        let firstTime = !warmedUp.contains(target.id)
        warmedUp.insert(target.id)
        usleep(firstTime && target.kind != .layout ? 350_000 : 120_000)
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
