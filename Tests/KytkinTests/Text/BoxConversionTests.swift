// P3-35: BoxConversion (001 §12.3 X11), pure, over the ABC / Apple Hebrew fixtures: the direction from the letter
// nearest the caret (before, else after), every letter of that side anywhere in the box, the shared-punctuation rule
// (P2-60 letters-only: `'` `"` `,` `.` next to Hebrew are kept), line breaks and tabs crossed, other controls bound
// the segment, window edges cut at word boundaries, and the caret math (with a length-changing fake converter).

import XCTest

final class BoxConversionTests: XCTestCase {
    private let layouts = ConvertFixtures.layouts

    /// The whole field, caret at `caret` (default: the end).
    private func box(_ text: String, caret: Int? = nil) -> FieldWindow {
        FieldWindow(text: text, location: 0, caret: caret ?? text.utf16.count, reachesFieldStart: true,
                    reachesFieldEnd: true)
    }

    private func plan(_ w: FieldWindow) -> BoxConversion.Result {
        BoxConversion.plan(w, classify: layouts.runClass) { side, g in
            layouts.converter(from: layouts.source(of: side))?.convert(g).text ?? g
        }
    }

    /// The box after applying the plan (the edit's range replaced by its text), or nil when nothing converts.
    private func converted(_ w: FieldWindow) -> String? {
        guard case .convert(let p) = plan(w) else { return nil }
        var units = Array(w.text.utf16)
        units.replaceSubrange(p.edit.offset..<(p.edit.offset + p.edit.length), with: Array(p.text.utf16))
        return String(decoding: units, as: UTF16.self)
    }

    private func edit(_ w: FieldWindow) -> FieldEdit? {
        if case .convert(let p) = plan(w) { return p.edit }
        return nil
    }

    // MARK: - Direction and the whole box

    func testOwnersExampleConvertsTheLatinAndKeepsTheHebrew() {
        let w = box("שלום akuo vh, nhv")
        XCTAssertEqual(converted(w), "שלום שלום הית מיה")
        guard case .convert(let p) = plan(w) else { return XCTFail("no plan") }
        XCTAssertEqual(p.side, .a)
        XCTAssertEqual(p.edit, FieldEdit(offset: 5, length: 12, caretAfter: nil), "ends at the caret")
    }

    /// Hebrew already correct and English typed wrong, both before and after the caret, over two lines.
    func testMixedBoxConvertsTheCaretSideLanguageBeforeAndAfterTheCaret() {
        let text = "שלום, מה akuo vh.\nnv תודה."
        let caret = "שלום, מה akuo vh.".utf16.count
        let w = box(text, caret: caret)
        XCTAssertEqual(converted(w), "שלום, מה שלום היץ\nמה תודה.")
        let e = edit(w)
        XCTAssertEqual(e?.offset, "שלום, מה ".utf16.count, "from the first changed letter")
        XCTAssertEqual(e?.length, "akuo vh.\nnv".utf16.count, "to the last changed letter")
        XCTAssertEqual(e?.caretAfter, caret, "the caret stays where it was")
    }

    func testTheDirectionIsTheNearestLetterBeforeTheCaret() {
        // The caret right after a Hebrew word: Hebrew converts, the Latin after it stays.
        let w = box("יקךךם akuo", caret: 5)
        XCTAssertEqual(converted(w), "hello akuo")
        XCTAssertEqual(edit(w), FieldEdit(offset: 0, length: 5, caretAfter: nil), "ends at the caret")
    }

    func testNoLetterBeforeTheCaretUsesTheNearestLetterAfter() {
        XCTAssertEqual(converted(box("akuo vh", caret: 0)), "שלום הי")
        XCTAssertEqual(edit(box("akuo vh", caret: 0))?.caretAfter, 0)
        XCTAssertEqual(converted(box("123 akuo", caret: 2)), "123 שלום")
    }

    func testAnEmptyNewLineAfterReturnConvertsTheBox() {
        let w = box("akuo vh\n")
        XCTAssertEqual(converted(w), "שלום הי\n")
        XCTAssertEqual(edit(w)?.caretAfter, 8, "the caret stays on the new line")
        // A blank line between paragraphs, caret on it: both paragraphs.
        let mid = box("akuo\n\nvh", caret: 5)
        XCTAssertEqual(converted(mid), "שלום\n\nהי")
        XCTAssertEqual(edit(mid)?.caretAfter, 5)
    }

    func testNothingToConvert() {
        XCTAssertEqual(plan(box("")), .nothing)
        XCTAssertEqual(plan(box("123 ,. -")), .nothing)
        XCTAssertEqual(plan(box("akuo привет")), .nothing, "another script nearest the caret")
        XCTAssertEqual(plan(box("\n\n")), .nothing)
    }

    func testOtherScriptsAndEmojiStay() {
        XCTAssertEqual(converted(box("привет akuo 😀 vh")), "привет שלום 😀 הי")
    }

    // MARK: - Shared and one-sided punctuation (P2-60 letters-only rule)

    func testPunctuationNextToHebrewIsKept() {
        // ASCII `'` (one-sided: only ABC types it) after Hebrew letters, digits, `,` and `.` next to Hebrew.
        XCTAssertEqual(converted(box("מס' 5, שלום. tkhk")), "מס' 5, שלום. אליל")
        XCTAssertEqual(converted(box("\"שלום\" akuo")), "\"שלום\" שלום")
        XCTAssertEqual(converted(box("פרופ' akuo")), "פרופ' שלום")
    }

    func testPunctuationInsideALatinWordConvertsByItsKey() {
        // `,` and `.` on ABC are ת and ץ on Hebrew: inside or at the edge of a Latin word they were typed for those.
        XCTAssertEqual(converted(box("vh, nv.")), "הית מהץ")
        XCTAssertEqual(converted(box("שלום ,usv")), "שלום תודה", "a word that starts with `,`")
    }

    func testAPunctuationBetweenTheTwoLanguagesInOneWordStays() {
        // No space between: the `,` touches a Hebrew letter, so its role is ambiguous; only the Latin converts.
        XCTAssertEqual(converted(box("שלום,akuo")), "שלום,שלום")
        XCTAssertEqual(converted(box("akuo,שלום", caret: 4)), "שלום,שלום")
    }

    func testALonePunctuationTokenStays() {
        XCTAssertEqual(converted(box("akuo , vh - nv")), "שלום , הי - מה")
    }

    // MARK: - Separators and stops

    func testLineBreaksAndTabsAreCrossedAndKept() {
        XCTAssertEqual(converted(box("akuo\tvh\r\nnv\u{2028}x")), "שלום\tהי\r\nמה\u{2028}ס")
    }

    func testAnotherControlCharacterBoundsTheSegment() {
        XCTAssertEqual(converted(box("akuo\u{1B}vh")), "akuo\u{1B}הי")
        XCTAssertEqual(converted(box("akuo\u{1B}vh", caret: 2)), "שלום\u{1B}vh")
    }

    // MARK: - Window edges (a box bigger than the cap)

    func testAWindowThatDoesNotReachTheFieldStartLeavesItsFirstWordAlone() {
        let w = FieldWindow(text: "uo vh", location: 10, caret: 15, reachesFieldStart: false, reachesFieldEnd: true)
        XCTAssertEqual(converted(w), "uo הי")
        XCTAssertEqual(edit(w), FieldEdit(offset: 3, length: 2, caretAfter: nil))
    }

    func testAWindowThatDoesNotReachTheFieldEndLeavesItsLastWordAlone() {
        let w = FieldWindow(text: "akuo vh nh", location: 0, caret: 4, reachesFieldStart: true, reachesFieldEnd: false)
        XCTAssertEqual(converted(w), "שלום הי nh")
    }

    func testAWindowEndingAtTheCaretKeepsTheWordAtTheCaret() {
        // The field's length was unknown: the window ends at the caret, which is never treated as a cut.
        let w = FieldWindow(text: "kuo vh", location: 1, caret: 7, reachesFieldStart: false, reachesFieldEnd: false)
        XCTAssertEqual(converted(w), "kuo הי")
    }

    func testOneWordBiggerThanTheWindowIsTooLong() {
        let w = FieldWindow(text: "aaaaaaaa", location: 5, caret: 9, reachesFieldStart: false, reachesFieldEnd: false)
        XCTAssertEqual(plan(w), .tooLong)
    }

    // MARK: - Caret math

    /// A fake pair where `a` converts to two units, so the caret has to move by the length change before it.
    private func longer(_ w: FieldWindow) -> BoxConversion.Result {
        BoxConversion.plan(w, classify: { $0 == " " ? .space : ($0 == "a" ? .strong(.a) : .strong(.b)) }) { _, g in
            g == "a" ? "XY" : g
        }
    }

    func testTheCaretMovesByTheLengthChangeBeforeIt() {
        guard case .convert(let p) = longer(box("a a a", caret: 3)) else { return XCTFail("no plan") }
        XCTAssertEqual(p.text, "XY XY XY")
        XCTAssertEqual(p.edit, FieldEdit(offset: 0, length: 5, caretAfter: 5), "after the second a, now XY")
        guard case .convert(let before) = longer(box("  a", caret: 1)) else { return XCTFail("no plan") }
        XCTAssertEqual(before.edit.caretAfter, 1, "a caret before the range doesn't move")
        guard case .convert(let after) = longer(box("a  ", caret: 3)) else { return XCTFail("no plan") }
        XCTAssertEqual(after.edit.caretAfter, 4, "a caret after the range moves by the change")
        guard case .convert(let at) = longer(box("a", caret: 1)) else { return XCTFail("no plan") }
        XCTAssertNil(at.edit.caretAfter, "a range ending at the caret: right after the new text")
    }

    func testOffsetsAreUTF16WithEmojiBefore() {
        let w = box("😀 akuo")
        XCTAssertEqual(edit(w), FieldEdit(offset: 3, length: 4, caretAfter: nil))
    }

    // MARK: - P3-35 QA additions

    /// P3-35 QA: correct English with its punctuation, Hebrew typed wrong at the caret: only the Hebrew converts; the
    /// `'` `,` `.` `/` `;` `-` inside or next to English words are left alone.
    func testCorrectEnglishPunctuationIsKeptWhenHebrewConverts() {
        XCTAssertEqual(converted(box("don't, stop. and/or; e-mail יקךךם")), "don't, stop. and/or; e-mail hello")
    }

    /// P3-35 QA: Hebrew with gershayim / geresh written with ASCII `"` `'`, `-` and `/` between Hebrew letters, and
    /// a Hebrew sentence with `,` `.` `;`, all kept while the Latin word after them converts.
    func testHebrewAbbreviationsAndSentencePunctuationAreKept() {
        let hebrew = "ש\"ח, צה\"ל; מס' 3-4, ת/ז. שלום;"
        XCTAssertEqual(converted(box(hebrew + " akuo")), hebrew + " שלום")
    }

    /// P3-35 QA: CRLF is one grapheme of two units: crossed, written back unchanged, offsets in UTF-16.
    func testCRLFIsCrossedAndTheOffsetsCountBothUnits() {
        let w = box("שלום\r\nakuo\r\nvh")
        XCTAssertEqual(converted(w), "שלום\r\nשלום\r\nהי")
        XCTAssertEqual(edit(w), FieldEdit(offset: 6, length: 8, caretAfter: nil))
    }

    /// P3-35 QA: a window that starts on a combining mark (cut after its base letter) or ends on half an emoji
    /// (decoded as U+FFFD) leaves those cut words alone.
    func testAWindowCutInsideAGraphemeLeavesThatWordAlone() {
        let start = FieldWindow(text: "\u{301}vh akuo", location: 40, caret: 48, reachesFieldStart: false,
                                reachesFieldEnd: true)
        XCTAssertEqual(converted(start), "\u{301}vh שלום")
        let end = FieldWindow(text: "akuo vh\u{FFFD}", location: 0, caret: 4, reachesFieldStart: true,
                              reachesFieldEnd: false)
        XCTAssertEqual(converted(end), "שלום vh\u{FFFD}")
    }

    /// P3-35 QA: the caret inside a long last word that the window's end cut (the ¼ after the caret was too short):
    /// that word stays, the direction comes from the letters before it, and the caret is kept.
    func testTheCaretInsideTheCutLastWordKeepsThatWord() {
        let w = FieldWindow(text: "akuo vhvhvhvh", location: 0, caret: 7, reachesFieldStart: true,
                            reachesFieldEnd: false)
        XCTAssertEqual(converted(w), "שלום vhvhvhvh")
        XCTAssertEqual(edit(w)?.caretAfter, 7)
    }

    /// P3-35 QA: the owner's direction rule, its known risk: the caret right after one correct Hebrew word in a box
    /// of wrong English converts the Hebrew (the nearest letter decides). Pinned so a change is deliberate; selecting
    /// the English first converts only it.
    func testTheNearestLetterDecidesEvenInAMostlyOtherLanguageBox() {
        XCTAssertEqual(converted(box("akuo vh nv שלום")), "akuo vh nv akuo")
    }

    // MARK: - P3-44: mentions and shortcodes are atomic

    private func converted(_ w: FieldWindow, atoms: [String]) -> String? {
        guard case .convert(let p) = BoxConversion.plan(w, classify: layouts.runClass, atomicTexts: atoms, convert: {
            side, g in self.layouts.converter(from: self.layouts.source(of: side))?.convert(g).text ?? g
        }) else { return nil }
        var units = Array(w.text.utf16)
        units.replaceSubrange(p.edit.offset..<(p.edit.offset + p.edit.length), with: Array(p.text.utf16))
        return String(decoding: units, as: UTF16.self)
    }

    func testOwnersSlackBoxKeepsTheMentionAndTheShortcode() {
        // P3-44 owner test, as the clipboard's plain text showed it: the mention's first word and the emoji's shortcode
        // were converted (`@יורךקך`, `:חסט:`). Now only the typed line converts.
        let w = box("שלום @Hillel Banai :joy:\nakuo vh")
        XCTAssertEqual(converted(w, atoms: ["@Hillel Banai"]), "שלום @Hillel Banai :joy:\nשלום הי")
        // Without the pill's text (no AX tree): the @word and the shortcode still stay; the pill's second word can't
        // be told from typed text.
        XCTAssertEqual(converted(w), "שלום @Hillel נשמשן :joy:\nשלום הי")
    }

    func testAMentionNeverDecidesTheDirection() {
        // The caret right after the mention: the nearest letter outside it (Hebrew) decides, nothing English converts.
        let w = box("שלום @akuo", caret: "שלום @akuo".utf16.count)
        XCTAssertEqual(converted(w), "akuo @akuo")
    }

    func testShortcodes() {
        XCTAssertEqual(converted(box("vh :smile: vh")), "הי :smile: הי")
        XCTAssertEqual(converted(box("vh :+1::white_check_mark: vh")), "הי :+1::white_check_mark: הי")
        XCTAssertEqual(converted(box("vh:joy:")), "הי:joy:", "a shortcode right after a word")
        XCTAssertEqual(converted(box("vh :: vh")), "הי :: הי", "no letters: nothing to keep")
        XCTAssertEqual(converted(box("vh :not closed")), "הי :מםא בךםדקג", "an unclosed colon is not a shortcode")
    }

    func testAPlainLatinWordStillConverts() {
        XCTAssertEqual(converted(box("a@b vh")), "ש@נ הי", "@ inside a word is not a mention")
        XCTAssertEqual(converted(box("@ vh")), "@ הי", "a lone @ is not a mention")
    }

    func testWebAddressesAreKept() {
        XCTAssertEqual(converted(box("vh https://example.com vh")), "הי https://example.com הי")
        XCTAssertEqual(converted(box("vh www.example.com")), "הי www.example.com")
    }

    func testAtomicTextsAreKeptWhereverTheyOccur() {
        XCTAssertEqual(converted(box("Hillel Banai vh"), atoms: ["Hillel Banai"]), "Hillel Banai הי")
        XCTAssertEqual(converted(box("vh"), atoms: ["x"]), "הי", "one-character atoms are ignored")
    }
}
