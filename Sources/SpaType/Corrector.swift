import CoreGraphics
import Foundation
import os
import SpaTypeCore

/// Debug diagnostics: `log stream --level debug --predicate 'subsystem == "SpaType"'`
let log = Logger(subsystem: "SpaType", category: "debug")

/// Applies a suggestion: delete what's on screen, put the intended text in, and switch input source.
///
/// From a plain layout to Korean or another layout, the finished text is typed directly and the
/// source is switched afterwards, so a slow IME switch can't turn the result back into the old layout.
/// Japanese (and anything typed through an input method) replays the same physical keys after the
/// switch, so the real IME does the kana/kanji conversion exactly as if typed by hand.
final class Corrector {
    private let queue = DispatchQueue(label: "spatype.corrector")
    private(set) var isBusy = false
    /// Keys the user typed while a correction was running (main thread). Replayed afterwards through the
    /// new source, so typing on through an auto-conversion neither interleaves nor comes out in the old layout.
    private var pending: [KeyStroke] = []

    func enqueue(_ stroke: KeyStroke) { pending.append(stroke) }

    func apply(_ suggestion: Suggestion, catalog: InputSourceCatalog, completion: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        queue.async {
            let source = CGEventSource(stateID: .privateState)
            // Let the key that triggered this (the space, for an auto-conversion) reach the app first.
            usleep(30_000)

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
                    // Verified: an unconfirmed CJK select can leave TIS saying 한글 while the app still types ABC.
                    self.switchInputSource(to: suggestion.target, catalog: catalog)
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

            // Checking for more keys and leaving the busy state happen together on main, so a key typed
            // in between can't be swallowed without being replayed.
            while true {
                let keys: [KeyStroke] = DispatchQueue.main.sync {
                    let keys = self.pending
                    self.pending = []
                    if keys.isEmpty {
                        self.isBusy = false
                        completion()
                    }
                    return keys
                }
                if keys.isEmpty { break }
                for stroke in keys {
                    Self.press(CGKeyCode(stroke.keyCode), shift: stroke.shift, source: source)
                    usleep(4_000)
                }
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
        func waitForSwitch() -> Bool {
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline, !isCurrent() { usleep(15_000) }
            return isCurrent()
        }

        // Press the user's own "Select the previous input source" shortcut first. A switch requested from a
        // background app (TISSelectInputSource) can leave the menu bar on 한 while the frontmost app keeps
        // typing ABC; the shortcut goes through the same path as a manual switch, so the app follows.
        // It only lands on `target` when that is the previous source (always, with two sources).
        if let hotkey = Self.previousSourceHotkey() {
            let source = CGEventSource(stateID: .privateState)
            if isCurrent() {
                // The system already says `target`, yet we're correcting text typed in another source: the app
                // missed that switch. Go to the previous source and back so the app follows this time.
                Self.press(hotkey.keyCode, modifiers: hotkey.flags, source: source)
                let deadline = Date().addingTimeInterval(0.8)
                while Date() < deadline, isCurrent() { usleep(15_000) }
                usleep(60_000)
            }
            Self.press(hotkey.keyCode, modifiers: hotkey.flags, source: source)
            if waitForSwitch() {
                usleep(120_000)   // let the app finish switching before keys are replayed
                return
            }
            log.debug("previous-source shortcut didn't land on \(target.id, privacy: .public); selecting directly")
        }

        for attempt in 0..<2 {
            DispatchQueue.main.sync { catalog.select(target) }
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline, !isCurrent() { usleep(15_000) }
            if isCurrent() { break }
            if attempt == 0 { usleep(50_000) }   // known TIS flakiness with CJK sources: select again
        }
        if !isCurrent() { log.debug("switch to \(target.id, privacy: .public) not confirmed") }

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

    /// The "Select the previous input source" shortcut (System Settings › Keyboard › Keyboard Shortcuts ›
    /// Input Sources), or nil when it's turned off. Untouched, it isn't in the plist: macOS default ⌃Space.
    private static func previousSourceHotkey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
        guard let entry = (all as? [String: Any])?["60"] as? [String: Any] else { return (49, .maskControl) }
        guard (entry["enabled"] as? Bool) == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3, parameters[1] != 65535
        else { return nil }
        return (CGKeyCode(parameters[1]), CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    /// A shortcut press: modifier keys down, the key, modifiers up, so system hotkeys see a real chord.
    private static func press(_ keyCode: CGKeyCode, modifiers: CGEventFlags, source: CGEventSource?) {
        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, 59), (.maskAlternate, 58), (.maskCommand, 55), (.maskShift, 56),
        ].filter { modifiers.contains($0.0) }
        var held: CGEventFlags = []
        for (flag, key) in modifierKeys {
            held.insert(flag)
            post(key, down: true, flags: held, source: source)
        }
        post(keyCode, down: true, flags: held, source: source)
        post(keyCode, down: false, flags: held, source: source)
        for (flag, key) in modifierKeys.reversed() {
            held.remove(flag)
            post(key, down: false, flags: held, source: source)
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
