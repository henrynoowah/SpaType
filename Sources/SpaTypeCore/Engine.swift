import Foundation

/// An enabled keyboard input source, as the engine sees it.
public struct SourceDescriptor: Hashable {
    public enum Kind: Hashable {
        /// A plain keyboard layout (ABC, Russian, Greek, Hebrew …). The app renders it with UCKeyTranslate.
        case layout
        /// Korean 2-set (두벌식) input method.
        case korean2Set
        /// Japanese romaji input (hiragana mode).
        case japaneseRomaji
    }

    public let id: String
    /// BCP-47-ish language code ("en", "ko", "ja", "ru" …).
    public let language: String
    public let kind: Kind
    public let displayName: String

    public init(id: String, language: String, kind: Kind, displayName: String) {
        self.id = id
        self.language = language
        self.kind = kind
        self.displayName = displayName
    }
}

/// Renders keystrokes through a plain keyboard layout (implemented by the app with UCKeyTranslate).
public protocol LayoutRendering {
    func render(_ strokes: [KeyStroke], in source: SourceDescriptor) -> String
}

/// Scores a word in a language, 0…1 (implemented by the app with NSSpellChecker / NLLanguageRecognizer).
public protocol WordJudging {
    func plausibility(of word: String, language: String) -> Double
}

public struct Suggestion: Equatable {
    public let from: SourceDescriptor
    public let target: SourceDescriptor
    /// What is on screen now (rendered through the current source).
    public let original: String
    /// What the user meant (rendered through the target source).
    public let preview: String
    /// Characters to delete before replaying.
    public let deleteCount: Int
    /// Keystrokes to replay after switching to `target`.
    public let replay: [KeyStroke]
    /// The exact text the replay produces in `target` (spaces included), minus `tailReplay`. Used to
    /// type the result directly when that doesn't need the target's input method (Korean, plain layouts).
    public let replacement: String
    /// Keys of a Korean syllable still being composed (accepted mid-word): replayed through the IME after
    /// `replacement`, so the user's next key can still join it ("한글로ㄱ" + ㅏ → "한글로가").
    public let tailReplay: [KeyStroke]
}

public final class Engine {
    public struct Config {
        /// Words shorter than this (in letters) never start a correction on their own.
        public var minLetters = 3
        /// The current rendering must score at or below this to be considered wrong.
        public var currentMax = 0.35
        /// The alternative rendering must score at least this.
        public var targetMin = 0.8
        /// …and beat the current rendering by this much.
        public var margin = 0.45
        /// Short/ambiguous words extend an existing run if they score this high in the run's language.
        public var extendMin = 0.9
        /// How many not-clearly-correct words right before a detection get folded into the run.
        public var maxLeadingWords = 6
        /// A word typed this long without a space is judged on every keystroke (no pause or space needed),
        /// e.g. a whole Korean sentence typed as "gksrmffhrkqwkrl…" with no spaces.
        public var liveWordMinKeys = 6
        /// Key sequences that are almost always a slip when typed on their own, even if they happen to be
        /// a real word in the current layout ("spa" is 넴). Keyed by the US-QWERTY keys, value = target language.
        /// Ignored right after a word that was clearly typed on purpose ("the spa").
        public var commonSlips: [String: String] = [
            "sp": "ko", "spa": "ko", "spq": "ko", "spd": "ko", "spsp": "ko",   // 네 넴 넵 넹 네네
            "dmd": "ko", "dnd": "ko", "dpd": "ko", "gjf": "ko",                 // 응 웅 엥 헐
        ]
        public init() {}
    }

    public var config = Config()
    private let layoutRenderer: LayoutRendering
    private let judge: WordJudging

    /// Letters typed since the last space.
    public private(set) var currentWord: [KeyStroke] = []
    /// Consecutive words (each including its trailing space) that look like they were typed in the wrong source.
    private var runWords: [[KeyStroke]] = []
    private var runFrom: SourceDescriptor?
    private var runTarget: SourceDescriptor?
    /// Recent words (since the last clearly-correct one) that might belong to a run that hasn't started yet,
    /// e.g. the short "dl" (이) before "rjt" (것) is detected.
    private var leadingWords: [[KeyStroke]] = []
    private var lastSource: SourceDescriptor?
    /// The previous word was clearly meant for the current source (so a common slip is probably intentional).
    private var afterIntendedWord = false
    /// After a line break (Enter) inside a run we still know the user is in the wrong source:
    /// the next line is judged against this target right away, even mid-word and for short words.
    private var primedFrom: SourceDescriptor?
    private var primedTarget: SourceDescriptor?

    public init(layoutRenderer: LayoutRendering, judge: WordJudging) {
        self.layoutRenderer = layoutRenderer
        self.judge = judge
    }

    public func reset() {
        currentWord = []
        afterIntendedWord = false
        primedFrom = nil
        primedTarget = nil
        clearRun()
    }

    public func backspace() {
        guard currentWord.isEmpty else {
            currentWord.removeLast()
            return
        }
        // Deleting back into the run (fixing a typo after the space): reopen its last word.
        guard var last = runWords.popLast() else {
            reset()
            return
        }
        last.removeLast()
        if last.last?.isSpace == true {
            runWords.append(last)          // removed one of several trailing spaces
        } else {
            currentWord = last             // back inside the word; it is judged again at the next space
        }
        leadingWords = []
        if runWords.isEmpty {
            runFrom = nil
            runTarget = nil
        }
    }

    /// Feeds one keystroke typed while `current` was active.
    /// Returns a suggestion only right after a word boundary (space), when one applies.
    @discardableResult
    public func type(_ stroke: KeyStroke, current: SourceDescriptor, alternatives: [SourceDescriptor]) -> Suggestion? {
        if let last = lastSource, last != current {
            clearRun()
            primedFrom = nil
            primedTarget = nil
        }
        lastSource = current
        guard stroke.isSpace else {
            currentWord.append(stroke)
            return nil
        }
        let word = currentWord
        currentWord = []

        if word.isEmpty {
            // Extra spaces belong to the run so they get deleted and replayed too.
            guard !runWords.isEmpty else { return nil }
            runWords[runWords.count - 1].append(stroke)
            return currentSuggestion()
        }

        let typed = word + [stroke]
        let verdict = judgeWord(word, current: current, alternatives: alternatives)
        if case .mismatch(let target) = verdict {
            if runTarget != target {
                // A new run: pull in the ambiguous words typed just before it ("dl rjt" -> "이 것").
                runWords = leadingRun(for: target)
                runTarget = target
            }
            runFrom = current
            runWords.append(typed)
            leadingWords = []
        } else if let target = runTarget {
            if score(word, in: target) >= config.extendMin || !looksCorrect(word, in: current) {
                // Inside a run, keep going unless the word is clearly meant for the current source.
                // Typos, numbers and short words ride along so the whole sentence gets fixed at once.
                runWords.append(typed)
            } else {
                clearRun()
            }
        } else if looksCorrect(word, in: current) {
            leadingWords = []
        } else {
            leadingWords.append(typed)
            if leadingWords.count > config.maxLeadingWords { leadingWords.removeFirst() }
        }
        afterIntendedWord = runWords.isEmpty && looksCorrect(word, in: current)
        if afterIntendedWord {
            primedFrom = nil
            primedTarget = nil
        }
        return currentSuggestion()
    }

    /// Called when typing pauses mid-word (no space yet — e.g. "spa" right before Enter).
    /// Judges the half-typed word as if it had ended; doesn't change any state.
    public func pauseSuggestion(current: SourceDescriptor, alternatives: [SourceDescriptor]) -> Suggestion? {
        guard !currentWord.isEmpty, lastSource == current else { return nil }
        if hasRun { return currentSuggestion(includingCurrentWord: true) }
        guard let target = midWordTarget(current: current, alternatives: alternatives) else { return nil }
        return makeSuggestion(leadingRun(for: target).flatMap { $0 } + currentWord, from: current, target: target)
    }

    /// The current word is long enough to be judged live, keystroke by keystroke.
    public var isLongWord: Bool { currentWord.count >= config.liveWordMinKeys }

    /// Judges the half-typed word. Mid-word the last key is often a consonant still waiting for its
    /// vowel ("gksr" → 한ㄱ), so if the whole word doesn't pass, the word minus its last key may.
    private func midWordTarget(current: SourceDescriptor, alternatives: [SourceDescriptor]) -> SourceDescriptor? {
        if case .mismatch(let target) = judgeWord(currentWord, current: current, alternatives: alternatives) {
            return target
        }
        guard currentWord.count > config.minLetters,
              case .mismatch(let target) = judgeWord(Array(currentWord.dropLast()), current: current, alternatives: alternatives)
        else { return nil }
        return target
    }

    /// Return/Enter: the text so far is committed (or sent), but if we were mid-run the user is
    /// almost certainly still in the wrong source — remember that for the next line.
    public func lineBreak() {
        let from = runFrom ?? primedFrom
        let target = runTarget ?? primedTarget
        reset()
        primedFrom = from
        primedTarget = target
    }

    /// A run is in progress, or the next line is primed: judge every keystroke, not just at spaces.
    public var isHot: Bool { hasRun || primedTarget != nil }

    /// Whether a run is in progress (a suggestion exists or will once the current word ends).
    public var hasRun: Bool { !runWords.isEmpty }

    /// The suggestion for the run so far. With `includingCurrentWord`, the half-typed word is fixed too
    /// (used when the user accepts mid-word).
    public func currentSuggestion(includingCurrentWord: Bool = false) -> Suggestion? {
        guard let from = runFrom, let target = runTarget, !runWords.isEmpty else { return nil }
        var all = runWords.flatMap { $0 }
        if includingCurrentWord { all += currentWord }
        return makeSuggestion(all, from: from, target: target)
    }

    private func makeSuggestion(_ all: [KeyStroke], from: SourceDescriptor, target: SourceDescriptor) -> Suggestion {
        let original = render(all, in: from)
        let replay = target.kind == .japaneseRomaji ? all.filter { !$0.isSpace } : all
        var preview = render(replay, in: target)
        if target.kind == .japaneseRomaji { preview = preview.trimmingCharacters(in: .whitespaces) }
        let direct = directText(replay, target: target)
        return Suggestion(
            from: from, target: target,
            original: original.trimmingCharacters(in: .whitespaces),
            preview: preview.trimmingCharacters(in: .whitespaces),
            deleteCount: original.count,
            replay: replay,
            replacement: direct.text,
            tailReplay: direct.tail
        )
    }

    /// Splits off the last Korean syllable when the suggestion ends mid-word (no trailing space).
    private func directText(_ replay: [KeyStroke], target: SourceDescriptor) -> (text: String, tail: [KeyStroke]) {
        let full = render(replay, in: target)
        guard target.kind == .korean2Set, let last = replay.last, !last.isSpace else { return (full, []) }
        for k in 1...min(5, replay.count) {
            let head = render(Array(replay.dropLast(k)), in: target)
            let tail = render(Array(replay.suffix(k)), in: target)
            if tail.count == 1, head + tail == full { return (head, Array(replay.suffix(k))) }
        }
        return (full, [])
    }

    // MARK: - Judging

    enum Verdict: Equatable { case fine, weak, mismatch(SourceDescriptor) }


    func judgeWord(_ word: [KeyStroke], current: SourceDescriptor, alternatives: [SourceDescriptor]) -> Verdict {
        // Japanese as the *current* source leaves marked text on screen; not supported in the MVP.
        guard current.kind != .japaneseRomaji else { return .fine }
        if !afterIntendedWord, let target = slipTarget(word, current: current, alternatives: alternatives) {
            return .mismatch(target)
        }
        if let target = primedTarget, primedFrom == current,
           score(word, in: target) >= config.extendMin, !looksCorrect(word, in: current) {
            return .mismatch(target)
        }
        guard let currentText = Self.normalized(render(word, in: current)) else { return .fine }
        guard currentText.filter(\.isLetter).count >= config.minLetters else { return .weak }

        let currentScore = score(word, in: current)
        guard currentScore <= config.currentMax else { return .fine }

        var best: (SourceDescriptor, Double)?
        for alt in alternatives where alt != current && alt.language != current.language {
            let s = score(word, in: alt)
            if s > (best?.1 ?? -1) { best = (alt, s) }
        }
        guard let winner = best,
              winner.1 >= config.targetMin,
              winner.1 - currentScore >= config.margin
        else { return .fine }
        return .mismatch(winner.0)
    }

    func score(_ word: [KeyStroke], in source: SourceDescriptor) -> Double {
        switch source.kind {
        case .korean2Set:
            return Dubeolsik.compose(word).plausibility
        case .japaneseRomaji:
            return Romaji.convert(word).plausibility
        case .layout:
            guard let text = Self.normalized(render(word, in: source)) else { return 0 }
            return judge.plausibility(of: text, language: source.language)
        }
    }

    func render(_ strokes: [KeyStroke], in source: SourceDescriptor) -> String {
        switch source.kind {
        case .korean2Set: return Dubeolsik.compose(strokes).text
        case .japaneseRomaji: return Romaji.convert(strokes).text
        case .layout: return layoutRenderer.render(strokes, in: source)
        }
    }

    /// Trims surrounding punctuation; returns nil for things that look like code, numbers or URLs.
    static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "ー" }) else {
            return nil
        }
        return trimmed
    }

    private func slipTarget(_ word: [KeyStroke], current: SourceDescriptor, alternatives: [SourceDescriptor]) -> SourceDescriptor? {
        let keys = String(word.compactMap(\.ascii))
        guard keys.count == word.count, let language = config.commonSlips[keys], language != current.language
        else { return nil }
        return alternatives.first { $0.language == language && score(word, in: $0) >= config.targetMin }
    }

    /// The longest suffix of `leadingWords` that reads as the target language.
    private func leadingRun(for target: SourceDescriptor) -> [[KeyStroke]] {
        var taken: [[KeyStroke]] = []
        for typed in leadingWords.reversed() {
            let letters = typed.filter { !$0.isSpace }
            guard score(letters, in: target) >= config.extendMin else { break }
            taken.insert(typed, at: 0)
        }
        return taken
    }

    /// The word reads as intended in `source` (so it isn't part of a wrong-source run).
    private func looksCorrect(_ word: [KeyStroke], in source: SourceDescriptor) -> Bool {
        guard Self.normalized(render(word, in: source)) != nil else { return false }
        return score(word, in: source) > config.currentMax
    }

    private func clearRun() {
        leadingWords = []
        runWords = []
        runFrom = nil
        runTarget = nil
    }
}
