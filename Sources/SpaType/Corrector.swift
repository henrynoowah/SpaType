import CoreGraphics
import Foundation
import SpaTypeCore

/// Applies a suggestion: delete what's on screen, put the intended text in, and switch input source.
///
/// From a plain layout to Korean or another layout, the finished text is typed directly and the
/// source is switched afterwards, so a slow IME switch can't turn the result back into the old layout.
/// Japanese (and anything typed through an input method) replays the same physical keys after the
/// switch, so the real IME does the kana/kanji conversion exactly as if typed by hand.
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

            if suggestion.from.kind == .layout, suggestion.target.kind != .japaneseRomaji {
                // Typed in a plain layout (no input method in the way): type the finished text directly,
                // then switch. The result can't come out in the old layout however slowly the target
                // input method wakes up — the switch only matters for what the user types next.
                for character in suggestion.replacement {
                    Self.type(character, source: source)
                    usleep(3_000)
                }
                usleep(20_000)
                if suggestion.tailReplay.isEmpty {
                    DispatchQueue.main.sync { catalog.select(suggestion.target) }
                } else {
                    // A syllable still being composed goes through the IME so the next key can join it.
                    self.switchInputSource(to: suggestion.target, catalog: catalog)
                    for stroke in suggestion.tailReplay {
                        Self.press(CGKeyCode(stroke.keyCode), shift: stroke.shift, source: source)
                        usleep(4_000)
                    }
                }
            } else {
                // Japanese needs its IME for kana/kanji conversion, and when the current source is an
                // input method the typed text could be captured by it: switch first, then replay keys.
                self.switchInputSource(to: suggestion.target, catalog: catalog)
                for stroke in suggestion.replay {
                    Self.press(CGKeyCode(stroke.keyCode), shift: stroke.shift, source: source)
                    usleep(4_000)
                }
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

    /// Posts one character as text (not as a key), so no keyboard layout or input method interprets it.
    private static func type(_ character: Character, source: CGEventSource?) {
        var units = Array(String(character).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            event.setIntegerValueField(.eventSourceUserData, value: KeyMonitor.injectedMarker)
            event.post(tap: .cghidEventTap)
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
