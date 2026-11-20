import XCTest
@testable import SpaTypeCore

final class HangulTests: XCTestCase {
    func testComposesUserExample() {
        XCTAssertEqual(Dubeolsik.compose(ascii: "gksrmffh rkqwkrl qkRuTdmf Eo").text, "한글로 갑자기 바꼈을 때")
    }

    func testFinalMovesToNextSyllable() {
        XCTAssertEqual(Dubeolsik.compose(ascii: "dkssudgktpdy").text, "안녕하세요")
        XCTAssertEqual(Dubeolsik.compose(ascii: "dlfrdj").text, "읽어")   // ㄹ+ㄱ -> ㄺ
        XCTAssertEqual(Dubeolsik.compose(ascii: "dlfrj").text, "일거")    // ㄺ + ㅓ splits
        XCTAssertEqual(Dubeolsik.compose(ascii: "rhkswl").text, "관지")
    }

    func testEnglishLooksLikeBrokenKorean() {
        let hello = Dubeolsik.compose(ascii: "hello")
        XCTAssertEqual(hello.text, "ㅗ디ㅣㅐ")
        XCTAssertGreaterThan(hello.orphanJamoCount, 0)
        XCTAssertLessThan(hello.plausibility, 0.35)
        XCTAssertEqual(Dubeolsik.compose(ascii: "gksrmf").plausibility, 1.0)
    }
}

final class RomajiTests: XCTestCase {
    func testBasics() {
        XCTAssertEqual(Romaji.convert(ascii: "konnichiha").text, "こんにちは")
        XCTAssertEqual(Romaji.convert(ascii: "arigatou").text, "ありがとう")
        XCTAssertEqual(Romaji.convert(ascii: "kitte").text, "きって")
        XCTAssertEqual(Romaji.convert(ascii: "toukyou").text, "とうきょう")
        XCTAssertEqual(Romaji.convert(ascii: "shinbun").text, "しんぶん")
    }

    func testEnglishIsNotRomaji() {
        XCTAssertEqual(Romaji.convert(ascii: "hello").text, "へっぉ")
        XCTAssertLessThan(Romaji.convert(ascii: "hello").plausibility, 0.8)
        XCTAssertLessThan(Romaji.convert(ascii: "world").plausibility, 0.8)
        XCTAssertEqual(Romaji.convert(ascii: "arigatou").plausibility, 1.0)
    }
}

// MARK: - Engine

private struct FakeLayouts: LayoutRendering {
    /// Minimal ЙЦУКЕН for the keys used in tests.
    static let russian: [Character: Character] = [
        "g": "п", "h": "р", "b": "и", "d": "в", "t": "е", "n": "т", "v": "м", "j": "о", "k": "л", "l": "д",
        "r": "к", "e": "у", "y": "н", "u": "г", "i": "ш", "o": "щ", "p": "з", "a": "ф", "s": "ы", "f": "а",
        "q": "й", "w": "ц", "z": "я", "x": "ч", "c": "с", "m": "ь", ",": "б", ".": "ю", " ": " ",
    ]
    func render(_ strokes: [KeyStroke], in source: SourceDescriptor) -> String {
        let ascii = String(strokes.compactMap { $0.ascii })
        switch source.language {
        case "ru": return String(ascii.lowercased().map { Self.russian[$0] ?? $0 })
        default: return ascii
        }
    }
}

private struct FakeJudge: WordJudging {
    let words: [String: Set<String>] = [
        "en": ["hello", "world", "the", "and", "make", "spa"],
        "ru": ["привет", "мир"],
    ]
    /// One letter off a real word ("wkf" ~ "wok"): SpellJudge scores these 0.45.
    let nearMisses: Set<String> = ["wkf"]
    func plausibility(of word: String, language: String) -> Double {
        if words[language]?.contains(word.lowercased()) == true { return 1.0 }
        return language == "en" && nearMisses.contains(word.lowercased()) ? 0.45 : 0.1
    }
}

final class EngineTests: XCTestCase {
    let en = SourceDescriptor(id: "abc", language: "en", kind: .layout, displayName: "ABC")
    let ko = SourceDescriptor(id: "ko", language: "ko", kind: .korean2Set, displayName: "2-Set Korean")
    let ja = SourceDescriptor(id: "ja", language: "ja", kind: .japaneseRomaji, displayName: "Hiragana")
    let ru = SourceDescriptor(id: "ru", language: "ru", kind: .layout, displayName: "Russian")

    func testSuggestionForArbitraryStrokes() {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        let s = engine.suggestion(for: KeyStroke.from(ascii: "dkssud wkf"), from: en, target: ko)
        XCTAssertEqual(s.preview, "안녕 잘")
        XCTAssertEqual(s.original, "dkssud wkf")
        XCTAssertEqual(s.deleteCount, 10)
    }

    func feed(_ text: String, current: SourceDescriptor, alternatives: [SourceDescriptor]) -> Suggestion? {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        var last: Suggestion?
        for stroke in KeyStroke.from(ascii: text) {
            last = engine.type(stroke, current: current, alternatives: alternatives)
        }
        return last
    }

    func testEnglishToKoreanRunAcrossWords() throws {
        let s = try XCTUnwrap(feed("gksrmffh rkqwkrl qkRuTdmf Eo ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.target, ko)
        XCTAssertEqual(s.preview, "한글로 갑자기 바꼈을 때")
        XCTAssertEqual(s.deleteCount, "gksrmffh rkqwkrl qkRuTdmf Eo ".count)
        XCTAssertEqual(s.replay.count, "gksrmffh rkqwkrl qkRuTdmf Eo ".count)
    }

    func testReplacementIsTheExactTextIncludingSpaces() throws {
        let s = try XCTUnwrap(feed("gksrmffh rkqwkrl ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.replacement, "한글로 갑자기 ", "typed directly, so the trailing space must be kept")
    }

    func testMidWordKeepsLastSyllableForTheIME() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh rk") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.currentSuggestion(includingCurrentWord: true))
        XCTAssertEqual(s.replacement, "한글로 ")
        XCTAssertEqual(s.tailReplay, KeyStroke.from(ascii: "rk"), "가 stays open for a following ㄴ etc.")
    }

    func testDanglingConsonantIsTheTail() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffhr") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
        // The ㄱ becomes 로's final consonant (록), so the whole syllable stays open for the IME:
        // a following vowel then splits it back into 로 + 가, just like typing by hand.
        XCTAssertEqual(s.replacement, "한글")
        XCTAssertEqual(s.tailReplay, KeyStroke.from(ascii: "fhr"))
    }

    func testKoreanToEnglish() throws {
        let s = try XCTUnwrap(feed("hello world ", current: ko, alternatives: [en, ko]))
        XCTAssertEqual(s.target, en)
        XCTAssertEqual(s.preview, "hello world")
        XCTAssertEqual(s.original, "ㅗ디ㅣㅐ 재깅")
        XCTAssertEqual(s.deleteCount, "ㅗ디ㅣㅐ 재깅 ".count)
    }

    func testEnglishToJapanese() throws {
        let s = try XCTUnwrap(feed("arigatou ", current: en, alternatives: [en, ja]))
        XCTAssertEqual(s.target, ja)
        XCTAssertEqual(s.preview, "ありがとう")
        XCTAssertFalse(s.replay.contains { $0.isSpace }, "space would trigger kanji conversion")
    }

    func testEnglishToRussian() throws {
        let s = try XCTUnwrap(feed("ghbdtn ", current: en, alternatives: [en, ru, ko]))
        XCTAssertEqual(s.target, ru)
        XCTAssertEqual(s.preview, "привет")
    }

    func testRealWordsAreLeftAlone() {
        XCTAssertNil(feed("hello and make ", current: en, alternatives: [en, ko, ja]))
    }

    func testCodeIsLeftAlone() {
        XCTAssertNil(feed("gks2rmf ", current: en, alternatives: [en, ko]))
    }

    func testShortWordsBeforeDetectionJoinTheRun() throws {
        let s = try XCTUnwrap(feed("dl rjtdms dkwlr ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "이 것은 아직")
        XCTAssertEqual(s.deleteCount, "dl rjtdms dkwlr ".count)
    }

    func testNearMissWordBeforeDetectionJoinsTheRun() throws {
        // "wkf" looks like an English typo of "wok", but reads as 잘 and the sentence goes on in Korean.
        let s = try XCTUnwrap(feed("wkf ehlrh dlTsk ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "잘 되고 있나")
        XCTAssertEqual(s.deleteCount, "wkf ehlrh dlTsk ".count)
    }

    func testRealEnglishWordStillEndsTheLeadingWords() throws {
        let s = try XCTUnwrap(feed("the ehlrh dlTsk ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "되고 있나")
    }

    func testTypoInsideRunDoesNotDropEarlierWords() throws {
        // "rkqwkrlk" has a stray ㅏ, so it isn't clean Korean — but it isn't English either.
        let text = "gksrmffh rkqwkrlk qkRuTdmf "
        let s = try XCTUnwrap(feed(text, current: en, alternatives: [en, ko]))
        XCTAssertTrue(s.preview.hasPrefix("한글로 "))
        XCTAssertTrue(s.preview.hasSuffix(" 바꼈을"))
        XCTAssertEqual(s.deleteCount, text.count)
    }

    func testBackspaceAfterSpaceReopensWord() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh rkqwkr ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        engine.backspace()   // the space
        engine.backspace()   // the stray "r"
        for stroke in KeyStroke.from(ascii: "rl ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.currentSuggestion())
        XCTAssertEqual(s.preview, "한글로 갑자기")
        XCTAssertEqual(s.deleteCount, "gksrmffh rkqwkrl ".count)
    }

    func testAcceptMidWordIncludesHalfTypedWord() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh rkqw") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        XCTAssertTrue(engine.hasRun)
        let s = try XCTUnwrap(engine.currentSuggestion(includingCurrentWord: true))
        XCTAssertEqual(s.preview, "한글로 갑ㅈ")
        XCTAssertEqual(s.deleteCount, "gksrmffh rkqw".count)
    }

    func testCommonSlipIsFixedOnItsOwn() throws {
        let s = try XCTUnwrap(feed("spa ", current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "넴")
    }

    func testCommonSlipAfterRealWordIsLeftAlone() {
        XCTAssertNil(feed("the spa ", current: en, alternatives: [en, ko]))
    }

    func testPauseSuggestionFixesWordBeforeEnter() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "spq") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "넵")
        XCTAssertEqual(s.deleteCount, 3)
        XCTAssertEqual(s.replay.count, 3, "no trailing space is added")
        XCTAssertTrue(engine.currentWord.count == 3, "pausing must not consume the word")
    }

    func testPauseSuggestionIgnoresRealWords() {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "hello") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        XCTAssertNil(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
    }

    func testNextLineIsPrimedAfterEnter() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        engine.lineBreak()
        XCTAssertTrue(engine.isHot)
        // A short word that wouldn't start a run on its own is caught mid-word on the primed line.
        for stroke in KeyStroke.from(ascii: "dl") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "이")
        XCTAssertEqual(s.deleteCount, 2, "only the new line is fixed")
    }

    func testPrimedLineEndsOnRealWord() {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        engine.lineBreak()
        for stroke in KeyStroke.from(ascii: "hello ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        XCTAssertFalse(engine.isHot)
    }

    func testPrimedLineDropsWhenSourceChanges() {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffh ") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        engine.lineBreak()
        for stroke in KeyStroke.from(ascii: "dl") { engine.type(stroke, current: ko, alternatives: [en, ko]) }
        XCTAssertNil(engine.pauseSuggestion(current: ko, alternatives: [en, ko]))
    }

    func testLongWordWithoutSpacesIsJudgedLive() throws {
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffhrkqwkrl") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        XCTAssertTrue(engine.isLongWord)
        let s = try XCTUnwrap(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.preview, "한글로갑자기")
        XCTAssertEqual(s.deleteCount, "gksrmffhrkqwkrl".count)
    }

    func testLongWordEndingInDanglingConsonantStillMatches() throws {
        // "gksrmffhr" = 한글록 — the ㄱ is waiting to move on to a following vowel.
        let engine = Engine(layoutRenderer: FakeLayouts(), judge: FakeJudge())
        for stroke in KeyStroke.from(ascii: "gksrmffhr") { engine.type(stroke, current: en, alternatives: [en, ko]) }
        let s = try XCTUnwrap(engine.pauseSuggestion(current: en, alternatives: [en, ko]))
        XCTAssertEqual(s.target, ko)
        XCTAssertEqual(s.replay.count, 9, "the dangling key is replayed too")
    }

    func testRunEndsOnCorrectWord() {
        XCTAssertNil(feed("gksrmf hello ", current: en, alternatives: [en, ko]))
    }
}
