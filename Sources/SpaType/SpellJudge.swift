import AppKit
import NaturalLanguage
import SpaTypeCore

/// Scores words with the system spell checker, falling back to language identification.
final class SpellJudge: WordJudging {
    private let checker = NSSpellChecker.shared
    private lazy var available = Set(checker.availableLanguages)

    func plausibility(of word: String, language: String) -> Double {
        if let spellLanguage = spellLanguage(for: language) {
            let miss = checker.checkSpelling(
                of: word, startingAt: 0, language: spellLanguage,
                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            )
            if miss.location == NSNotFound { return 1.0 }

            // A near-miss ("teh") is a typo, not a wrong input source — don't flag it as gibberish.
            let range = NSRange(location: 0, length: (word as NSString).length)
            let guesses = checker.guesses(
                forWordRange: range, in: word, language: spellLanguage, inSpellDocumentWithTag: 0
            ) ?? []
            let lower = word.lowercased()
            if guesses.contains(where: { Self.editDistance($0.lowercased(), lower) <= 1 }) { return 0.45 }
            return 0.1
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(word)
        return recognizer.languageHypotheses(withMaximum: 5)[NLLanguage(rawValue: language)] ?? 0
    }

    private func spellLanguage(for code: String) -> String? {
        if available.contains(code) { return code }
        return available.sorted().first { $0.hasPrefix(code + "_") }
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
