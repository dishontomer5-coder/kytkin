// P2-59: LayoutSnapshot's run answers (001 §12.3 X1, X5, X8) over the real ABC / Apple Hebrew fixtures: the grapheme
// classes, and the whole buffer typed / rendered with the spaces between its words.

import XCTest

final class LayoutSnapshotRunTests: XCTestCase {
    private let s = ConvertFixtures.layouts

    /// The minimal input `typedRun`/`renderRun` take until P2-59a's `WordSnapshot.gaps` lands.
    private struct Run: BufferedRun {
        var strokes: [Stroke]
        var previousWords: [[Stroke]]
        var gaps: [Int]
    }

    private func k(_ text: String) -> [Stroke] { ConvertFixtures.strokes(text) }

    // MARK: - runClass

    func testLatinLettersAreStrongAAndHebrewLettersStrongB() {
        for ch: Character in ["a", "z", "A", "Z", "Q"] { XCTAssertEqual(s.runClass(of: ch), .strong(.a), "\(ch)") }
        for ch: Character in ["ש", "ל", "ו", "ם", "ת", "ץ", "ף"] {
            XCTAssertEqual(s.runClass(of: ch), .strong(.b), "\(ch)")
        }
    }

    func testDigitsAndSharedPunctuationAreShared() {
        for ch: Character in ["1", "0", ",", ".", ";", "/", "-", "="] {
            XCTAssertEqual(s.runClass(of: ch), .shared, "\(ch)")
        }
    }

    func testSpacesAndHardStops() {
        XCTAssertEqual(s.runClass(of: " "), .space)
        XCTAssertEqual(s.runClass(of: "\u{00A0}"), .space, "no-break space")
        for ch: Character in ["\n", "\r", "\r\n", "\t", "\u{2028}", "\u{2029}", "\u{0}", "\u{1B}"] {
            XCTAssertEqual(s.runClass(of: ch), .hardStop, ch.debugDescription)
        }
    }

    func testForeignGraphemes() {
        XCTAssertEqual(s.runClass(of: "п"), .foreignLetter)
        XCTAssertEqual(s.runClass(of: "ж"), .foreignLetter)
        XCTAssertEqual(s.runClass(of: "😀"), .foreignOther)
        XCTAssertEqual(s.runClass(of: "👍🏽"), .foreignOther)
        XCTAssertEqual(s.runClass(of: "€"), .foreignOther)
    }

    func testAGraphemeNeitherIndexHasIsClassedByItsFirstScalar() {
        XCTAssertEqual(s.runClass(of: "שָׁ"), .strong(.b), "niqqud on a Hebrew letter")
        XCTAssertEqual(s.runClass(of: "e\u{301}"), .strong(.a), "e + combining acute")
        XCTAssertEqual(s.runClass(of: "\u{E9}"), .foreignLetter, "precomposed é: no plain/shift key types it")
        XCTAssertEqual(s.runClass(of: "לֹ"), .strong(.b), "typed whole by Apple Hebrew Shift+K")
    }

    func testSidesMapToThePairIDs() {
        XCTAssertEqual(s.source(of: .a), IDs.abc)
        XCTAssertEqual(s.source(of: .b), IDs.hebrew)
        XCTAssertEqual(s.side(of: IDs.hebrew), .b)
        XCTAssertNil(s.side(of: IDs.russian))
        XCTAssertEqual(PairSide.a.other, .b)
    }

    // MARK: - typedRun / renderRun

    func testTheWholeBufferJoinsWordsWithTheirSpaces() {
        let r = Run(strokes: k("nhv"), previousWords: [k("akuo"), k("vh,")], gaps: [1, 2])
        XCTAssertEqual(s.typedRun(r, in: IDs.abc), "akuo vh,  nhv")
        XCTAssertEqual(s.renderRun(r, from: IDs.abc)?.text, "שלום הית  מיה")
        XCTAssertEqual(s.renderRun(r, from: IDs.abc)?.target, IDs.hebrew)
        XCTAssertEqual(s.typedRun(r, in: IDs.hebrew), "שלום הית  מיה")
        XCTAssertEqual(s.renderRun(r, from: IDs.hebrew)?.text, "akuo vh,  nhv")
        XCTAssertEqual(s.typedRun(r, in: IDs.abc)?.count, 13)
    }

    func testTrailingSpacesWithNoCurrentWord() {
        let r = Run(strokes: [], previousWords: [k("akuo")], gaps: [2])
        XCTAssertEqual(s.typedRun(r, in: IDs.abc), "akuo  ")
        XCTAssertEqual(s.renderRun(r, from: IDs.abc)?.text, "שלום  ")
    }

    func testNoRunIsNil() {
        let r = Run(strokes: [], previousWords: [], gaps: [])
        XCTAssertNil(s.typedRun(r, in: IDs.abc))
        XCTAssertNil(s.renderRun(r, from: IDs.abc))
    }

    func testAMismatchedGapCountIsNil() {
        XCTAssertNil(s.typedRun(Run(strokes: k("vh"), previousWords: [k("akuo")], gaps: []), in: IDs.abc))
        XCTAssertNil(s.typedRun(Run(strokes: k("vh"), previousWords: [k("akuo")], gaps: [-1]), in: IDs.abc))
    }

    func testOutsideThePairIsNil() {
        let r = Run(strokes: k("akuo"), previousWords: [], gaps: [])
        XCTAssertNil(s.typedRun(r, in: IDs.russian))
        XCTAssertNil(s.renderRun(r, from: IDs.russian))
    }

    func testADeadKeyInAnyWordIsNil() {
        let r = Run(strokes: k("vh"), previousWords: [[Stroke(keyCode: 14, layer: .option)] + k("akuo")], gaps: [1])
        XCTAssertNil(s.typedRun(r, in: IDs.abc))
        XCTAssertNil(s.renderRun(r, from: IDs.abc))
    }

    func testACombiningMarkIsNil() {
        // ⌥W on Apple Hebrew types a qamats that joins the letter before it.
        let joined = Run(strokes: [Stroke(keyCode: 0, layer: .plain), Stroke(keyCode: 13, layer: .option)],
                         previousWords: [], gaps: [])
        XCTAssertNil(s.typedRun(joined, in: IDs.hebrew))
        // One key that types a pointed letter (Shift+A = שׁ) is one grapheme but two scalars: Backspace counts differ
        // between apps (P2-49 item 1), so the key path must not count it.
        let pointed = Run(strokes: [Stroke(keyCode: 0, layer: .shift)], previousWords: [], gaps: [])
        XCTAssertEqual(s.typed(pointed.strokes, in: IDs.hebrew), "שׁ")
        XCTAssertNil(s.typedRun(pointed, in: IDs.hebrew))
        XCTAssertNil(s.renderRun(pointed, from: IDs.hebrew))
    }
}
