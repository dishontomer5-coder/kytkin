// P2-59: RunBeforeCaret.scan (001 §12.3 X1, X2, X3, X8) over the real ABC / Apple Hebrew and ABC / Hebrew-PC
// fixtures: direction from the strong grapheme nearest the caret, stops, mid-token cuts, the left trim with the
// comma rule, the right end at the caret, the 256-unit cap at a word boundary, line breaks, and UTF-16 offsets.

import XCTest

final class RunBeforeCaretTests: XCTestCase {
    private let he = ConvertFixtures.layouts
    private let hePC = LayoutSnapshot(pair: LanguagePair(a: IDs.abc, b: InputSourceID("com.apple.keylayout.Hebrew-PC")),
                                      a: ConvertFixtures.abc, b: ConvertFixtures.map("Hebrew-PC"))!

    /// The run's text and side, `"nothing"` or `"tooLong"`.
    private func run(_ text: String, atStart: Bool = true, in layouts: LayoutSnapshot? = nil) -> String {
        let l = layouts ?? he
        let w = BeforeCaretWindow(text: text, location: 1000, reachesFieldStart: atStart)
        switch RunBeforeCaret.scan(w, classify: l.runClass) {
        case .nothing: return "nothing"
        case .tooLong: return "tooLong"
        case let .run(loc, side):
            let units = Array(text.utf16)
            XCTAssertEqual(loc.offset + loc.length, units.count, "the run ends at the caret")
            let s = String(decoding: units[loc.offset..<(loc.offset + loc.length)], as: UTF16.self)
            return "\(side == .a ? "A" : "B"):\(s)"
        }
    }

    // MARK: - The owner's example and the X8 list

    func testOwnersExample() {
        XCTAssertEqual(run("שלום akuo vh, nhv"), "A:akuo vh, nhv")
    }

    func testCommaAtWordStart() {
        XCTAssertEqual(run(",usv"), "A:,usv", "at the field start")
        XCTAssertEqual(run("שלום ,usv"), "A:,usv", "a token preceded by a space keeps its leading comma")
        XCTAssertEqual(run("שלום , akuo"), "A:akuo", "a lone comma is trimmed")
        XCTAssertEqual(run(", akuo"), "A:akuo")
        XCTAssertEqual(run("akuo , nhv"), "A:akuo , nhv", "inside the run it stays")
        XCTAssertEqual(run("akuo ,"), "A:akuo ,", "a trailing comma converts per the run's side")
    }

    func testMidTokenStop() {
        XCTAssertEqual(run("שלום,akuo"), "A:akuo", "the comma was typed before the switch")
        XCTAssertEqual(run("שלוםakuo"), "A:akuo")
        XCTAssertEqual(run("akuoשלום"), "B:שלום")
        XCTAssertEqual(run("שלום,123 akuo"), "A:akuo", "a cut token with no strong grapheme is dropped")
    }

    func testTrailingWeakTokensAndSpacesAreInTheRun() {
        XCTAssertEqual(run("akuo 123"), "A:akuo 123")
        XCTAssertEqual(run("akuo "), "A:akuo ")
        XCTAssertEqual(run("akuo  "), "A:akuo  ")
        XCTAssertEqual(run("שלום 123"), "B:שלום 123", "trailing digits are crossed to find the side")
        XCTAssertEqual(run("akuo 😀"), "A:akuo 😀")
    }

    func testNothingToConvert() {
        for text in ["123", ", .", "", " ", "😀", "123 ,"] {
            XCTAssertEqual(run(text), "nothing", text.debugDescription)
        }
    }

    func testLineBreaksAndControlCharactersStopTheRun() {
        XCTAssertEqual(run("line\nakuo vh"), "A:akuo vh")
        XCTAssertEqual(run("akuo\n"), "nothing")
        XCTAssertEqual(run("akuo\r\nvh"), "A:vh")
        XCTAssertEqual(run("akuo\rvh"), "A:vh")
        XCTAssertEqual(run("akuo\tvh"), "A:vh")
        XCTAssertEqual(run("akuo\u{2028}vh"), "A:vh")
        XCTAssertEqual(run("akuo\u{2029}vh"), "A:vh")
        // A hard stop makes the start known: a token right after it is never treated as cut.
        XCTAssertEqual(run("xx\nakuo", atStart: false), "A:akuo")
    }

    func testForeignScriptsAndEmoji() {
        XCTAssertEqual(run("привет akuo"), "A:akuo")
        XCTAssertEqual(run("akuo привет"), "nothing", "another script nearest the caret")
        XCTAssertEqual(run("приветakuo"), "A:akuo")
        XCTAssertEqual(run("akuoпривет"), "nothing")
        XCTAssertEqual(run("привет 123 akuo"), "A:akuo")
        XCTAssertEqual(run("😀 akuo"), "A:akuo", "a leading emoji token is trimmed")
        XCTAssertEqual(run("akuo😀vh"), "A:akuo😀vh", "an emoji inside a token passes through")
        XCTAssertEqual(run("שלום 👍🏽 akuo"), "A:akuo")
        XCTAssertEqual(run("akuo 👍🏽 vh"), "A:akuo 👍🏽 vh")
    }

    func testNiqqudIsStrongHebrew() {
        XCTAssertEqual(run("שָׁלוֹם akuo"), "A:akuo")
        XCTAssertEqual(run("akuo שָׁלוֹם"), "B:שָׁלוֹם")
    }

    func testSameScriptWordsStopTheRunOnHebrewPC() {
        // Hebrew-PC's Shift layer types Latin capitals, so `OK` is shared there: a word neither layout can tell.
        XCTAssertEqual(run("akuo OK nhv", in: hePC), "A:nhv")
        XCTAssertEqual(run("akuo OK", in: hePC), "nothing")
        XCTAssertEqual(run("akuo OK nhv", in: he), "A:akuo OK nhv", "on Apple Hebrew capitals are strong A")
        XCTAssertEqual(run("שלום akuo vh, nhv", in: hePC), "A:akuo vh, nhv")
    }

    // MARK: - Cap (X2)

    func testWindowNotAtTheFieldStartDropsTheCutToken() {
        XCTAssertEqual(run("kuo vh", atStart: false), "A:vh")
        XCTAssertEqual(run("23 akuo", atStart: false), "A:akuo")
        XCTAssertEqual(run("kuo", atStart: false), "tooLong")
    }

    func testWindowStartingWithASpaceKeepsItsFirstToken() {
        XCTAssertEqual(run(" akuo vh", atStart: false), "A:akuo vh")
    }

    func testASingleTokenLongerThanTheWindowIsTooLong() {
        let token = String(repeating: "a", count: 300)
        let window = String(token.suffix(ReplacementPlanner.maxRunReadChars))
        XCTAssertEqual(run(window, atStart: false), "tooLong")
        XCTAssertEqual(run(window + " ", atStart: false), "tooLong")
        XCTAssertEqual(run("שלום " + String(repeating: "a", count: 251)), "A:" + String(repeating: "a", count: 251),
                       "a long word that starts inside the window is fine")
    }

    func testLongRunIsCutAtAWordBoundary() {
        // 60 × "akuo " + "vh" = 302 units; the window holds the last 256, starting inside a word ("kuo akuo …").
        let line = String(repeating: "akuo ", count: 60) + "vh"
        let window = String(decoding: Array(line.utf16).suffix(256), as: UTF16.self)
        XCTAssertTrue(window.hasPrefix("kuo "))
        let expected = String(window.dropFirst(4))
        XCTAssertEqual(run(window, atStart: false), "A:" + expected)
    }

    func testAMidTokenStopInTheFirstTokenIsNotACut() {
        XCTAssertEqual(run("לוםakuo", atStart: false), "A:akuo")
    }

    // MARK: - Offsets

    func testOffsetsAreUTF16WithAstralGraphemesBeforeTheRun() {
        let w = BeforeCaretWindow(text: "😀😀 שלום 👍🏽 akuo vh", location: 40, reachesFieldStart: false)
        // 😀 = 2 units each, 👍🏽 = 4 units.
        guard case let .run(loc, side) = RunBeforeCaret.scan(w, classify: he.runClass) else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(side, .a)
        XCTAssertEqual(loc, RunLocation(offset: 2 + 2 + 1 + 4 + 1 + 4 + 1, length: 7))
    }
}
