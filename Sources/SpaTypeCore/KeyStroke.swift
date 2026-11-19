/// A physical key press, recorded independently of the active input source.
///
/// Recording key codes (not characters) is what makes the engine language-agnostic:
/// the same sequence can be re-interpreted under every enabled input source.
public struct KeyStroke: Hashable, CustomStringConvertible {
    public let keyCode: UInt16
    public let shift: Bool

    public init(keyCode: UInt16, shift: Bool) {
        self.keyCode = keyCode
        self.shift = shift
    }

    /// Character this key produces on a US ANSI QWERTY layout.
    /// Korean 2-set and Japanese romaji input are defined on these physical positions.
    public var ascii: Character? { USLayout.character(for: keyCode, shift: shift) }

    public var isSpace: Bool { keyCode == USLayout.space }

    public var description: String {
        ascii.map { String($0) } ?? "<\(keyCode)>"
    }

    /// Builds strokes from a US-layout string. Handy for tests and previews.
    public static func from(ascii text: String) -> [KeyStroke] {
        text.compactMap { USLayout.stroke(for: $0) }
    }
}

public enum USLayout {
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
    public static let tab: UInt16 = 48

    /// keyCode -> (unshifted, shifted) for the US ANSI layout.
    static let table: [UInt16: (Character, Character)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
        5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
        11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
        16: ("y", "Y"), 17: ("t", "T"), 18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"),
        21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("),
        26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"), 30: ("]", "}"),
        31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"),
        42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"),
        47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
    ]

    static let reverse: [Character: KeyStroke] = {
        var map: [Character: KeyStroke] = [:]
        for (code, pair) in table {
            map[pair.0] = KeyStroke(keyCode: code, shift: false)
            if pair.1 != pair.0 { map[pair.1] = KeyStroke(keyCode: code, shift: true) }
        }
        return map
    }()

    public static func character(for keyCode: UInt16, shift: Bool) -> Character? {
        guard let pair = table[keyCode] else { return nil }
        return shift ? pair.1 : pair.0
    }

    public static func stroke(for character: Character) -> KeyStroke? {
        reverse[character]
    }

    /// Keys that type text (letters, digits, punctuation, space) — everything else resets tracking.
    public static func isTextKey(_ keyCode: UInt16) -> Bool { table[keyCode] != nil }
}
