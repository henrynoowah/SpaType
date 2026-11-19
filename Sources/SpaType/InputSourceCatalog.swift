import Carbon
import Foundation
import SpaTypeCore

/// Enabled keyboard input sources, and rendering of keystrokes through plain layouts.
final class InputSourceCatalog: LayoutRendering {
    private(set) var sources: [SourceDescriptor] = []
    private var refs: [String: TISInputSource] = [:]
    private var layoutData: [String: Data] = [:]

    func reload() {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        // includeAllInstalled = false -> only the sources the user enabled in System Settings.
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return
        }
        var result: [SourceDescriptor] = []
        refs = [:]
        layoutData = [:]
        for source in list {
            guard let descriptor = Self.describe(source) else { continue }
            result.append(descriptor)
            refs[descriptor.id] = source
            if descriptor.kind == .layout, let data: NSData = Self.property(source, kTISPropertyUnicodeKeyLayoutData) {
                layoutData[descriptor.id] = data as Data
            }
        }
        sources = result
    }

    /// The active source, if it's one the engine understands.
    var current: SourceDescriptor? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let id: String = Self.property(source, kTISPropertyInputSourceID) else { return nil }
        return sources.first { $0.id == id }
    }

    func select(_ descriptor: SourceDescriptor) {
        guard let source = refs[descriptor.id] else { return }
        TISSelectInputSource(source)
    }

    // MARK: - LayoutRendering

    func render(_ strokes: [KeyStroke], in source: SourceDescriptor) -> String {
        guard let data = layoutData[source.id] else {
            return String(strokes.compactMap { $0.ascii })
        }
        var out = ""
        let keyboardType = UInt32(LMGetKbdType())
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for stroke in strokes {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                // Carbon modifier state is (EventModifiers >> 8) & 0xFF; shiftKey (0x0200) -> 0x02.
                let modifiers: UInt32 = stroke.shift ? 0x02 : 0
                let status = UCKeyTranslate(
                    layout, stroke.keyCode, UInt16(kUCKeyActionDown), modifiers, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                    chars.count, &length, &chars
                )
                if status == noErr, length > 0 {
                    out += String(utf16CodeUnits: chars, count: length)
                }
            }
        }
        return out
    }

    // MARK: - Helpers

    static func describe(_ source: TISInputSource) -> SourceDescriptor? {
        guard let id: String = property(source, kTISPropertyInputSourceID),
              let type: String = property(source, kTISPropertyInputSourceType)
        else { return nil }
        let name: String = property(source, kTISPropertyLocalizedName) ?? id
        let languages: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
        let language = languages.first.map { String($0.prefix { $0 != "-" && $0 != "_" }) } ?? "und"

        if type == (kTISTypeKeyboardLayout as String) {
            return SourceDescriptor(id: id, language: language, kind: .layout, displayName: name)
        }
        guard type == (kTISTypeKeyboardInputMode as String) else { return nil }

        if id.hasPrefix("com.apple.inputmethod.Korean.2SetKorean") {
            return SourceDescriptor(id: id, language: "ko", kind: .korean2Set, displayName: name)
        }
        // e.g. com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese (hiragana, romaji typing)
        if id.hasPrefix("com.apple.inputmethod.Kotoeri"), id.hasSuffix(".Japanese"), !id.contains("KanaTyping") {
            return SourceDescriptor(id: id, language: "ja", kind: .japaneseRomaji, displayName: name)
        }
        // Other input methods (3-set Korean, Pinyin, kana typing, third-party IMEs) aren't supported yet.
        return nil
    }

    static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }
}
