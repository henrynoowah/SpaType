import Foundation

/// Result of composing a key sequence with the Korean 2-set (두벌식) automaton.
public struct HangulComposition: Equatable {
    public let text: String
    /// Complete syllables (초성+중성[+종성]).
    public let syllableCount: Int
    /// Jamo left standing alone (e.g. "ㅗ", "ㄷ") — a strong sign the input wasn't Korean.
    public let orphanJamoCount: Int
    /// Syllables with finals that are rare in real text (ㄳ, ㄵ, ㄽ …).
    public let rareSyllableCount: Int

    /// 0…1 — how much this looks like intentional Korean.
    public var plausibility: Double {
        let total = syllableCount + orphanJamoCount
        guard total > 0 else { return 0 }
        var score = Double(syllableCount) / Double(total)
        if orphanJamoCount > 0 { score *= 0.5 }
        score *= pow(0.8, Double(rareSyllableCount))
        return score
    }
}

/// Korean 2-set (두벌식) keyboard: QWERTY positions -> jamo -> syllables.
public enum Dubeolsik {
    static let baseKeys: [Character: Character] = [
        "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
        "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
        "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
    ]
    static let shiftedKeys: [Character: Character] = [
        "Q": "ㅃ", "W": "ㅉ", "E": "ㄸ", "R": "ㄲ", "T": "ㅆ", "O": "ㅒ", "P": "ㅖ",
    ]

    static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let medials = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// Index + 1 is the final's index in the syllable formula (0 = no final).
    static let finals = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")

    static let vowelCompounds: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    static let finalCompounds: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]
    static let finalSplits: [Character: (Character, Character)] = [
        "ㄳ": ("ㄱ", "ㅅ"), "ㄵ": ("ㄴ", "ㅈ"), "ㄶ": ("ㄴ", "ㅎ"), "ㄺ": ("ㄹ", "ㄱ"), "ㄻ": ("ㄹ", "ㅁ"),
        "ㄼ": ("ㄹ", "ㅂ"), "ㄽ": ("ㄹ", "ㅅ"), "ㄾ": ("ㄹ", "ㅌ"), "ㄿ": ("ㄹ", "ㅍ"), "ㅀ": ("ㄹ", "ㅎ"),
        "ㅄ": ("ㅂ", "ㅅ"),
    ]
    static let rareFinals: Set<Character> = ["ㄳ", "ㄵ", "ㄽ", "ㄾ", "ㄿ", "ㅀ"]

    static func jamo(for ascii: Character) -> Character? {
        if let shifted = shiftedKeys[ascii] { return shifted }
        guard let lower = String(ascii).lowercased().first else { return nil }
        return baseKeys[lower]
    }

    static func syllable(_ initial: Character, _ medial: Character, _ final: Character?) -> Character {
        let i = initials.firstIndex(of: initial)!
        let m = medials.firstIndex(of: medial)!
        let f = final.flatMap { finals.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        return Character(UnicodeScalar(0xAC00 + (i * 21 + m) * 28 + f)!)
    }

    public static func compose(_ strokes: [KeyStroke]) -> HangulComposition {
        compose(ascii: String(strokes.compactMap { $0.ascii }))
    }

    public static func compose(ascii: String) -> HangulComposition {
        var out = ""
        var initial: Character?
        var medial: Character?
        var final: Character?
        var syllables = 0, orphans = 0, rare = 0

        func flush() {
            if let c = initial, let v = medial {
                out.append(syllable(c, v, final))
                syllables += 1
                if let f = final, rareFinals.contains(f) { rare += 1 }
            } else if let c = initial {
                out.append(c); orphans += 1
            } else if let v = medial {
                out.append(v); orphans += 1
            }
            initial = nil; medial = nil; final = nil
        }

        for ch in ascii {
            guard let j = jamo(for: ch) else {
                flush()
                out.append(ch)
                continue
            }
            if medials.contains(j) {
                // Vowel
                if medial == nil {
                    medial = j
                } else if final == nil {
                    if let combined = vowelCompounds[String([medial!, j])] {
                        medial = combined
                    } else {
                        flush(); medial = j
                    }
                } else {
                    // The final consonant moves to the next syllable (갑 + ㅣ -> 가비).
                    let moved: Character
                    if let split = finalSplits[final!] {
                        final = split.0; moved = split.1
                    } else {
                        moved = final!; final = nil
                    }
                    flush()
                    initial = moved; medial = j
                }
            } else {
                // Consonant
                if medial == nil {
                    if initial != nil { flush() }
                    initial = j
                } else if initial == nil {
                    flush(); initial = j
                } else if final == nil {
                    if finals.contains(j) { final = j } else { flush(); initial = j }
                } else if let combined = finalCompounds[String([final!, j])] {
                    final = combined
                } else {
                    flush(); initial = j
                }
            }
        }
        flush()
        return HangulComposition(text: out, syllableCount: syllables, orphanJamoCount: orphans, rareSyllableCount: rare)
    }
}
