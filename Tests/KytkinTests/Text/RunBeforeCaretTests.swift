// P2-59: RunBeforeCaret.scan (001 §12.3 X1, X2, X3, X8) over the real ABC / Apple Hebrew and ABC / Hebrew-PC
// fixtures: direction from the strong grapheme nearest the caret, stops, mid-token cuts, the left trim with the
// comma rule, the right end at the caret, the window cap at a word boundary, line breaks, and UTF-16 offsets.
// P3-33: the run crosses line breaks now (only tabs and other control characters are hard stops), and the window is
// 4,096 units; the tests that asserted the old line-break stop and the 256 window assert the new behaviour.

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

    /// P3-33: was "line breaks stop the run"; now a line break separates tokens like a space and the run crosses it.
    /// Tabs and other control characters still stop it.
    func testLineBreaksAreCrossedAndControlCharactersStopTheRun() {
        XCTAssertEqual(run("line\nakuo vh"), "A:line\nakuo vh")
        XCTAssertEqual(run("akuo\n"), "A:akuo\n", "a trailing line break is part of the run, like a trailing space")
        XCTAssertEqual(run("akuo\r\nvh"), "A:akuo\r\nvh")
        XCTAssertEqual(run("akuo\rvh"), "A:akuo\rvh")
        XCTAssertEqual(run("akuo\u{2028}vh"), "A:akuo\u{2028}vh")
        XCTAssertEqual(run("akuo\u{2029}vh"), "A:akuo\u{2029}vh")
        XCTAssertEqual(run("akuo\n\nvh"), "A:akuo\n\nvh", "a blank line too")
        XCTAssertEqual(run("akuo\tvh"), "A:vh", "a tab is still a hard stop")
        XCTAssertEqual(run("akuo\u{1B}vh"), "A:vh")
        // A hard stop makes the start known: a token right after it is never treated as cut.
        XCTAssertEqual(run("xx\takuo", atStart: false), "A:akuo")
        // A line break does not: the window's first token may still be cut, so it is dropped.
        XCTAssertEqual(run("xx\nakuo", atStart: false), "A:akuo")
        XCTAssertEqual(run("\nxx akuo", atStart: false), "A:xx akuo", "a window starting at a line break keeps its token")
    }

    /// P3-33: a multi-line wrong run stops where text already in the other language starts, even lines above.
    func testMultiLineRunStopsAtTheOtherLanguageAcrossLines() {
        XCTAssertEqual(run("שלום עולם\nakuo vh\nnhv"), "A:akuo vh\nnhv", "the Hebrew line above is kept")
        XCTAssertEqual(run("שלום\n\nakuo\nvh, nhv"), "A:akuo\nvh, nhv")
        XCTAssertEqual(run("hello\nשלום\nעולם"), "B:שלום\nעולם")
        XCTAssertEqual(run("akuo\nשלום,vh"), "A:vh", "a mid-token stop after the line break")
        XCTAssertEqual(run("привет\nakuo\nvh"), "A:akuo\nvh", "another script on the line above stops it")
        XCTAssertEqual(run("akuo\n123\nvh"), "A:akuo\n123\nvh", "digit lines inside the run are kept")
        XCTAssertEqual(run("שלום\n123\nakuo"), "A:akuo", "and trimmed at its start")
        // The P2-60 letters-only rule holds across lines: a one-sided `'` never starts or picks a run.
        XCTAssertEqual(run("מס' 5\ntkhk"), "A:tkhk")
    }

    /// P3-33 QA: pins today's behaviour on an empty new line (checklist §P3-33 step 8 asks the owner): the run crosses
    /// the line break back into the line above, so correct Hebrew there converts. Before P3-33 this was "nothing".
    func testAnEmptyNewLineConvertsTheLineAbove() {
        XCTAssertEqual(run("שלום עולם\n"), "B:שלום עולם\n")
        XCTAssertEqual(run("שלום עולם\r\n  "), "B:שלום עולם\r\n  ")
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

    // MARK: - One-sided punctuation (P2-60 QA)

    /// Apple Hebrew types no ASCII `'` or `"` (its keys give `׳` and `״`), so they are `strong(A)` non-letters. They
    /// must never pick the side or start a run: correct Hebrew with an ASCII apostrophe or quote (common in pasted
    /// text) kept its `'` → `,` otherwise.
    func testOneSidedPunctuationNeverDecidesOrStartsARun() {
        XCTAssertEqual(he.runClass(of: "'"), .strong(.a), "the premise: Apple Hebrew has no ASCII apostrophe")
        XCTAssertEqual(run("מס' 5 tkhk"), "A:tkhk", "was `' 5 tkhk`: the abbreviation's `'` became `,`")
        XCTAssertEqual(run("ראיתי את פרופ'"), "nothing", "was `'` → `,`; the Hebrew run stops at the ASCII `'`")
        XCTAssertEqual(run("הוא אמר \"שלום\" tkhk"), "A:tkhk", "was `\" tkhk`: the closing quote became `״`")
        XCTAssertEqual(run("גב' tkhk"), "A:tkhk")
        XCTAssertEqual(run("ג'hrpv"), "A:hrpv", "converting back after a split leaves the `'` alone")
        XCTAssertEqual(run("שלום ' akuo"), "A:akuo", "a lone one-sided `'` is trimmed like a lone comma")
        XCTAssertEqual(run("שלום '"), "nothing")
    }

    func testOneSidedPunctuationInsideItsOwnSideStillConverts() {
        XCTAssertEqual(run("akuo'"), "A:akuo'", "the ABC `'` key is the Hebrew comma")
        XCTAssertEqual(run("akuo' nv"), "A:akuo' nv")
        XCTAssertEqual(run("akuo '"), "A:akuo '", "trailing, it converts per the run's side")
        XCTAssertEqual(run("tbh \"tkhk\""), "A:tbh \"tkhk\"")
        XCTAssertEqual(run("צה״ל"), "B:צה״ל", "a real gershayim is Hebrew's own")
        XCTAssertEqual(run("ג'ירפה"), "B:ירפה", "a Hebrew run still stops at an ASCII `'` it has no key for")
    }

    /// Double-Shift on a correct Hebrew line, then double-Shift again after the X6 undo record expired: the text comes
    /// back exactly (or nothing is converted). Never a `'` → `,`.
    func testCorrectHebrewWithAsciiApostropheRoundTripsOrIsLeftAlone() {
        for line in ["מס' 5", "ראיתי את פרופ'", "ג'ירפה", "צה\"ל", "הוא אמר \"שלום\"", "רח' הרצל 5", "שלום, מה שלומך?"] {
            let once = convertRun(line)
            XCTAssertTrue(convertRun(once).unicodeScalars.elementsEqual(line.unicodeScalars),
                          "\(line) → \(once) → \(convertRun(once))")
        }
    }

    /// The text after one run convert (the run before the caret, converted by its side's converter).
    private func convertRun(_ text: String) -> String {
        let w = BeforeCaretWindow(text: text, location: 0, reachesFieldStart: true)
        guard case let .run(loc, side) = RunBeforeCaret.scan(w, classify: he.runClass),
              let c = he.converter(from: he.source(of: side)) else { return text }
        let units = Array(text.utf16)
        let head = String(decoding: units[..<loc.offset], as: UTF16.self)
        let tail = String(decoding: units[loc.offset...], as: UTF16.self)
        return head + c.convert(tail).text
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

    /// P3-33: the window is 4,096 units now (was 256).
    func testASingleTokenLongerThanTheWindowIsTooLong() {
        let cap = ReplacementPlanner.maxRunReadChars
        let token = String(repeating: "a", count: cap + 44)
        let window = String(token.suffix(cap))
        XCTAssertEqual(run(window, atStart: false), "tooLong")
        XCTAssertEqual(run(window + " ", atStart: false), "tooLong")
        XCTAssertEqual(run("שלום " + String(repeating: "a", count: cap - 5)), "A:" + String(repeating: "a", count: cap - 5),
                       "a long word that starts inside the window is fine")
    }

    func testLongRunIsCutAtAWordBoundary() {
        // 900 × "akuo " + "vh" = 4,502 units; the window holds the last 4,096, starting inside a word ("kuo akuo …").
        let line = String(repeating: "akuo ", count: 900) + "vh"
        let window = String(decoding: Array(line.utf16).suffix(ReplacementPlanner.maxRunReadChars), as: UTF16.self)
        XCTAssertTrue(window.hasPrefix("kuo "))
        let expected = String(window.dropFirst(4))
        XCTAssertEqual(run(window, atStart: false), "A:" + expected)
    }

    /// P3-33: a long multi-line run (≈ 3,000 units over 60 lines) converts whole when it reaches the field start.
    func testLongMultiLineRunConvertsWhole() {
        let text = String(repeating: String(repeating: "akuo ", count: 10) + "\n", count: 60) + "vh"
        XCTAssertLessThan(text.utf16.count, ReplacementPlanner.maxRunReadChars)
        XCTAssertEqual(run(text), "A:" + text)
        XCTAssertEqual(run("שלום\n" + text), "A:" + text)
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

    // MARK: - QA (P2-59b/c): adversarial mixes

    func testNoBreakSpaceAndBidiMarksNeverWidenTheRunPastTheOtherLanguage() {
        XCTAssertEqual(run("שלום\u{00A0}akuo\u{00A0}vh"), "A:akuo\u{00A0}vh", "NBSP is a space, not a stop")
        XCTAssertEqual(run("שלום\u{200F} akuo"), "A:akuo", "an RLM after Hebrew stays with the Hebrew")
        XCTAssertEqual(run("שלום \u{200F}akuo"), "A:\u{200F}akuo", "a mark that starts the token goes with it")
        XCTAssertEqual(run("akuo\u{200E}"), "A:akuo\u{200E}", "a trailing LRM passes through")
        XCTAssertEqual(run("שלום\u{2028}akuo"), "A:akuo", "U+2028 is a line break; the Hebrew before it stops the run")
    }

    func testDigitsAndPunctuationBetweenLanguagesAreTrimmed() {
        XCTAssertEqual(run("שלום 2024 akuo"), "A:akuo")
        XCTAssertEqual(run("שלום 2024"), "B:שלום 2024", "trailing weak tokens are crossed to find the side")
        XCTAssertEqual(run("hello 2024 שלום"), "B:שלום")
        XCTAssertEqual(run("(akuo)"), "A:(akuo)")
    }

    /// The owner double-Shifts on text that is already right. P3-33: was "only its line"; now its whole run, across
    /// lines, still never past text in the other language.
    func testCorrectTextConvertsItsWholeRunAcrossLines() {
        XCTAssertEqual(run("hello\nשלום עולם"), "B:שלום עולם")
        XCTAssertEqual(run("akuo\nhello world"), "A:akuo\nhello world")
    }

    /// The window can start inside a character the AX read cut: a lone low surrogate (U+FFFD once decoded) or a
    /// combining mark without its letter. That first token is never converted.
    func testAWindowStartingMidCharacterNeverConvertsTheCutToken() {
        let loneLow = String(decoding: [0xDE00] + Array("akuo vh".utf16), as: UTF16.self)
        XCTAssertEqual(run(loneLow, atStart: false), "A:vh")
        // A lone niqqud mark is alphabetic, so it classes as a foreign letter: a mid-token stop. That is right, since
        // in the field it sits on a Hebrew letter just before the window, so `akuo` starts after the other language.
        XCTAssertEqual(run("\u{05B8}akuo vh", atStart: false), "A:akuo vh")
        XCTAssertEqual(run("e\u{0301}akuo vh".unicodeScalars.dropFirst().map(String.init).joined(), atStart: false),
                       "A:vh", "a lone Latin accent is not a letter: the cut token is dropped")
        XCTAssertEqual(run("\u{05B8} akuo", atStart: false), "A:akuo", "a lone mark then a space: the run is whole")
    }

    func testEmojiSequencesInsideTheRunKeepTheirUnits() {
        let w = BeforeCaretWindow(text: "שלום akuo 👨‍👩‍👧 vh", location: 0, reachesFieldStart: true)
        guard case let .run(loc, .a) = RunBeforeCaret.scan(w, classify: he.runClass) else {
            return XCTFail("expected a Latin run")
        }
        XCTAssertEqual(loc.offset, 5)
        XCTAssertEqual(loc.length, "akuo 👨‍👩‍👧 vh".utf16.count)
    }
}
