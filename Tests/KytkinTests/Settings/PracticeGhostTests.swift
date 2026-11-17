// P6-0i: the setup's ghost practice word: the sample from the pair, the typing rules (forgiving, a wrong key turned
// away), the phases, the Shift caps, and the switch to the typing language when the step opens.

import XCTest

@MainActor
final class PracticeGhostTests: XCTestCase {
    private let sample = PracticeGhost.Sample(typed: "akuo", target: "שלום", typingSide: .a)

    // MARK: - The sample from the pair

    func testHebrewEnglishGivesAkuo() throws {
        let s = try XCTUnwrap(PracticeGhost.sample(layouts: ConvertFixtures.layouts))
        XCTAssertEqual(s, sample, "שלום on the English keys, typed with the first language")
    }

    func testTheWordSideIsFoundWhicheverWayRoundThePairIs() throws {
        let swapped = try XCTUnwrap(LayoutSnapshot(pair: LanguagePair(a: IDs.hebrew, b: IDs.abc),
                                                   a: ConvertFixtures.hebrew, b: ConvertFixtures.abc))
        let s = try XCTUnwrap(PracticeGhost.sample(layouts: swapped))
        XCTAssertEqual(s.typed, "akuo")
        XCTAssertEqual(s.typingSide, .b, "English is the second language here")
    }

    func testNoSampleWithoutLayoutsOrAWord() {
        XCTAssertNil(PracticeGhost.sample(layouts: nil))
        let latin = LayoutSnapshot(pair: LanguagePair(a: IDs.abc, b: InputSourceID("com.apple.keylayout.US")),
                                   a: ConvertFixtures.abc, b: ConvertFixtures.abc)
        XCTAssertNil(latin.flatMap(PracticeGhost.sample(layouts:)), "two Latin keyboards: the plain practice box")
        XCTAssertEqual(PracticeGhost.baseLanguage("he_IL"), "he")
    }

    // MARK: - Typing

    func testPhases() {
        XCTAssertEqual(PracticeGhost.phase(of: "", sample: sample), .typing(filled: 0))
        XCTAssertEqual(PracticeGhost.phase(of: "ak", sample: sample), .typing(filled: 2))
        XCTAssertEqual(PracticeGhost.phase(of: "AKU", sample: sample), .typing(filled: 3), "case doesn't matter")
        XCTAssertEqual(PracticeGhost.phase(of: "akuo", sample: sample), .wrongLanguage)
        XCTAssertEqual(PracticeGhost.phase(of: "שלום", sample: sample), .converted)
    }

    func testOnlyTheNextLetterIsTaken() {
        XCTAssertEqual(PracticeGhost.accept(old: "", new: "a", sample: sample), .init(text: "a", rejected: nil))
        XCTAssertEqual(PracticeGhost.accept(old: "a", new: "aK", sample: sample), .init(text: "ak", rejected: nil))
        XCTAssertEqual(PracticeGhost.accept(old: "ak", new: "akx", sample: sample), .init(text: "ak", rejected: "x"))
        XCTAssertEqual(PracticeGhost.accept(old: "ak", new: "akש", sample: sample), .init(text: "ak", rejected: "ש"),
                       "typed on the other keyboard: turned away")
        XCTAssertEqual(PracticeGhost.accept(old: "akuo", new: "akuoo", sample: sample),
                       .init(text: "akuo", rejected: "o"), "nothing after the last letter")
        XCTAssertEqual(PracticeGhost.accept(old: "ak", new: "a", sample: sample), .init(text: "a", rejected: nil),
                       "Backspace works")
        XCTAssertEqual(PracticeGhost.accept(old: "akuo", new: "", sample: sample), .init(text: "", rejected: nil))
        XCTAssertEqual(PracticeGhost.accept(old: "akuo", new: "שלום", sample: sample),
                       .init(text: "שלום", rejected: nil), "the converted word stays")
        XCTAssertEqual(PracticeGhost.accept(old: "שלום", new: "שלו", sample: sample), .init(text: "", rejected: nil),
                       "editing the converted word starts over")
    }

    func testVoiceOverProgress() {
        XCTAssertEqual(PracticeGhost.progressAnnouncement(filled: 2, sample: sample), "a, k typed")
        XCTAssertEqual(PracticeGhost.progressAnnouncement(filled: 0, sample: sample), "")
    }

    // QA (P6-0i): a key after the converted word is turned away; the word stays.
    func testAKeyAfterTheConvertedWordKeepsTheWord() {
        XCTAssertEqual(PracticeGhost.accept(old: "שלום", new: "שלוםx", sample: sample),
                       PracticeGhost.Edit(text: "שלום", rejected: "x"))
        XCTAssertEqual(PracticeGhost.accept(old: "שלום", new: "שלו", sample: sample),
                       PracticeGhost.Edit(text: "", rejected: nil), "Backspace starts over")
    }
}
