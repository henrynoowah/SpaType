import Foundation

/// Result of reading a key sequence as Japanese romaji input.
public struct KanaConversion: Equatable {
    public let text: String
    public let kanaCount: Int
    /// Letters that couldn't be read as romaji (e.g. "h" in "teh").
    public let leftoverLetters: Int
    public let totalLetters: Int
    public let hadUppercase: Bool
    /// Small kana typed with an x/l prefix (ぁ, ぉ …) — what English like "hello" (へっぉ) turns into.
    public let oddKanaCount: Int

    public var plausibility: Double {
        guard totalLetters > 0 else { return 0 }
        var score = Double(totalLetters - leftoverLetters) / Double(totalLetters)
        if leftoverLetters > 0 { score *= 0.4 }
        if kanaCount < 2 { score *= 0.5 }
        if hadUppercase { score *= 0.5 }
        score *= pow(0.3, Double(oddKanaCount))
        return score
    }
}

/// Romaji -> hiragana, close to what macOS 日本語 (ローマ字入力) produces before kanji conversion.
/// Only used for the preview and for scoring; the actual correction replays keystrokes through
/// the real IME, so conversion quirks here never end up in the user's text.
public enum Romaji {
    static let table: [String: String] = {
        var t: [String: String] = [
            "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
            "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
            "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
            "sa": "さ", "si": "し", "shi": "し", "su": "す", "se": "せ", "so": "そ",
            "za": "ざ", "zi": "じ", "ji": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
            "ta": "た", "ti": "ち", "chi": "ち", "tu": "つ", "tsu": "つ", "te": "て", "to": "と",
            "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
            "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
            "ha": "は", "hi": "ひ", "hu": "ふ", "fu": "ふ", "he": "へ", "ho": "ほ",
            "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
            "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
            "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
            "ya": "や", "yu": "ゆ", "yo": "よ",
            "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
            "wa": "わ", "wo": "を",
            "sha": "しゃ", "shu": "しゅ", "she": "しぇ", "sho": "しょ",
            "cha": "ちゃ", "chu": "ちゅ", "che": "ちぇ", "cho": "ちょ",
            "ja": "じゃ", "ju": "じゅ", "je": "じぇ", "jo": "じょ",
            "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
            "thi": "てぃ", "dhi": "でぃ",
            "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ", "xtu": "っ", "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ",
            "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ", "ltu": "っ", "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ",
            "-": "ー",
        ]
        // Contracted sounds: kya, gya, nya, ... and the sy/ty/zy spellings.
        let yoon: [String: String] = [
            "k": "き", "g": "ぎ", "n": "に", "h": "ひ", "b": "び", "p": "ぴ", "m": "み", "r": "り",
            "sy": "し", "ty": "ち", "cy": "ち", "zy": "じ", "jy": "じ", "dy": "ぢ",
        ]
        for (prefix, base) in yoon {
            let head = prefix.count == 1 ? prefix + "y" : prefix
            t[head + "a"] = base + "ゃ"
            t[head + "u"] = base + "ゅ"
            t[head + "o"] = base + "ょ"
        }
        return t
    }()

    static let vowels: Set<Character> = ["a", "i", "u", "e", "o"]

    public static func convert(_ strokes: [KeyStroke]) -> KanaConversion {
        convert(ascii: String(strokes.compactMap { $0.ascii }))
    }

    public static func convert(ascii: String) -> KanaConversion {
        let hadUppercase = ascii.contains { $0.isUppercase }
        let chars = Array(ascii.lowercased())
        var out = ""
        var kana = 0, leftover = 0, letters = 0, odd = 0
        var i = 0

        func emit(_ s: String) { out += s; kana += s.count }

        while i < chars.count {
            let c = chars[i]
            if c.isLetter { letters += 1 }

            // ん: "n" not followed by a vowel/"y" (n + n + vowel keeps the second n for the next kana).
            if c == "n" {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if let n = next, vowels.contains(n) || n == "y" {
                    // handled by the table below
                } else if next == "n" {
                    let after: Character? = i + 2 < chars.count ? chars[i + 2] : nil
                    if let a = after, vowels.contains(a) || a == "y" {
                        emit("ん"); i += 1; continue
                    }
                    emit("ん"); letters += 1; i += 2; continue
                } else {
                    emit("ん"); i += 1
                    if next == "'" { i += 1 }
                    continue
                }
            }

            // っ: doubled consonant (kk, tt, ss, tch …).
            if i + 1 < chars.count, c.isLetter, !vowels.contains(c), c != "n",
               chars[i + 1] == c || (c == "t" && chars[i + 1] == "c") {
                emit("っ"); i += 1; continue
            }

            var matched = false
            for length in stride(from: 3, through: 1, by: -1) where i + length <= chars.count {
                let key = String(chars[i..<(i + length)])
                if let k = table[key] {
                    emit(k)
                    if key.first == "x" || key.first == "l" { odd += 1 }
                    letters += key.dropFirst().filter { $0.isLetter }.count
                    i += length
                    matched = true
                    break
                }
            }
            if matched { continue }

            if c.isLetter { leftover += 1 }
            out.append(c)
            i += 1
        }
        return KanaConversion(text: out, kanaCount: kana, leftoverLetters: leftover, totalLetters: letters, hadUppercase: hadUppercase, oddKanaCount: odd)
    }
}
