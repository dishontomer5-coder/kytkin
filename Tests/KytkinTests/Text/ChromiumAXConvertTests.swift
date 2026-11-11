// P3-42 (001 §12.3 X15): `ChromiumAXConvert` against a fake Chromium/Electron web box (`FakeChromiumField`): only the
// changed pieces are selected and typed over (last to first), each selection is read back before typing (Slack's emoji
// drift → nothing typed, fall back), `AXSelectedText` / `AXValue` are never written (Chromium ignores / breaks them), LF
// line breaks are never typed, selections keep their line breaks, the budget and the focus are checked before each
// piece, typed keys must show before the next piece. Fakes only: no AX, no events, no real app.

import XCTest

final class ChromiumAXConvertTests: XCTestCase {
    private let layouts = ConvertFixtures.layouts
    private var clock: FakeClock!
    private var poster: RecordingPoster!

    override func setUp() {
        clock = FakeClock(nowNanos: 1_000_000_000)
        poster = RecordingPoster()
    }

    @TextActor private func field(_ text: String, caret: Int? = nil, selection: Range<Int>? = nil,
                       bold: Range<Int>? = nil) -> FakeChromiumField {
        FakeChromiumField(text, caret: caret, selection: selection, poster: poster, clock: clock, boldUnits: bold)
    }

    @TextActor private func sut(_ provider: any FocusedElementProviding, timing: ChromiumAXConvert.Timing = .init())
        -> ChromiumAXConvert {
        let clock = self.clock!
        return ChromiumAXConvert(focusProvider: provider, poster: poster, clock: clock, timing: timing,
                                 sleep: { nanos in clock.advance(byNanos: nanos) })
    }

    /// The controller's box plan (P3-35 `BoxConversion` over the whole box, caret-side direction).
    private func boxPlan(_ read: ChromiumAXConvert.Read) -> ChromiumAXConvert.Planned {
        let w = FieldWindow(text: read.text, location: 0, caret: read.selection.location, reachesFieldStart: true,
                            reachesFieldEnd: true)
        switch BoxConversion.plan(w, classify: layouts.runClass, convert: { side, g in
            self.layouts.converter(from: self.layouts.source(of: side))?.convert(g).text ?? g
        }) {
        case .nothing: return .nothing
        case .tooLong: return .tooLong
        case .convert(let p): return .changes(p.changes)
        }
    }

    /// The selection plan: per grapheme with the guessed layout.
    private func selectionPlan(_ read: ChromiumAXConvert.Read) -> ChromiumAXConvert.Planned {
        let units = Array(read.text.utf16)
        let s = read.selection
        let text = String(decoding: units[s.location..<s.end], as: UTF16.self)
        guard let g = layouts.convertGuessing(text), let c = layouts.converter(from: g.source) else { return .nothing }
        var out: [TextChange] = []
        var at = s.location
        for ch in text {
            let o = String(ch), n = c.convert(o).text
            if n != o { out.append(TextChange(offset: at, length: o.utf16.count, text: n)) }
            at += o.utf16.count
        }
        return .changes(out)
    }

    @TextActor private func run(_ f: FakeChromiumField, _ source: ChromiumAXConvert.Source = .box,
                     provider: (any FocusedElementProviding)? = nil, timing: ChromiumAXConvert.Timing = .init(),
                     claim: Bool = true) async -> ChromiumAXConvert.Result {
        let p = provider ?? SwitchableFocusProvider(f)
        return await sut(p, timing: timing).run(source, expected: f, plan: { read in
            source == .box ? self.boxPlan(read) : self.selectionPlan(read)
        }, mayWrite: { claim })
    }

    // MARK: - The benefit: only the changed letters are typed over

    @TextActor func testSlackBoldWordStaysBoldOnlyTheWrongWordIsTyped() async {
        // "שלום akuo": the Hebrew word is bold; the caret at the end decides English → Hebrew.
        let f = field("שלום akuo", bold: 0..<4)
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 1))
        XCTAssertEqual(f.text, "שלום שלום")
        XCTAssertEqual(f.boldText, "שלום", "the bold word was never retyped")
        XCTAssertEqual(poster.typed, "שלום", "only the changed piece was typed")
        XCTAssertEqual(f.rangeWrites.first, TextRange(location: 5, length: 4))
        XCTAssertEqual(f.range(.selectedTextRange), .success(TextRange(location: 9, length: 0)), "caret back at the end")
    }

    @TextActor func testBoldInsideAConvertedWordKeepsItsNeighboursFormatting() async {
        // "akuo **akuo**": both words convert; the second is bold and stays bold (typed over inside the bold run).
        let f = field("akuo akuo", bold: 5..<9)
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום")
        XCTAssertEqual(f.boldText, "שלום")
    }

    @TextActor func testPiecesGoLastToFirstAndTheCaretGoesBackToItsPlace() async {
        let f = field("akuo שלום akuo", caret: 4)
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום שלום")
        // Last piece first, then the first one, then the caret.
        XCTAssertEqual(f.rangeWrites, [TextRange(location: 10, length: 4), TextRange(location: 0, length: 4),
                                       TextRange(location: 4, length: 0)])
    }

    @TextActor func testNeverWritesSelectedTextOrValue() async {
        // Chromium: an AXSelectedText write is a silent no-op and an AXValue write breaks the editor.
        let f = field("akuo")
        _ = await run(f)
        XCTAssertEqual(f.selectedTextWrites, 0)
        XCTAssertEqual(f.valueWrites, 0)
        XCTAssertEqual(f.text, "שלום")
    }

    // MARK: - Slack's emoji (missing from AXValue)

    @TextActor func testEmojiMissingFromValueWithConsistentOffsetsConverts() async {
        // The page holds an emoji AXValue leaves out; the range set maps AX offsets correctly: the read-back agrees.
        let f = field("akuo 😀 akuo")
        f.hidden = 5..<7
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום 😀 שלום", "the emoji is untouched")
    }

    @TextActor func testEmojiOffsetDriftFailsTheReadBackAndTypesNothing() async {
        // Slack: offsets after the emoji land one emoji early when the range is set: the selected text read back is not
        // the expected piece, so nothing is typed, the caret goes back, and the caller falls back (the clipboard).
        let f = field("akuo 😀 akuo")
        f.hidden = 5..<7
        f.setRangeDrifts = true
        let result = await run(f)
        XCTAssertEqual(result, .unavailable(.selectionMismatch))
        XCTAssertTrue(poster.events.isEmpty, "nothing typed")
        XCTAssertEqual(f.text, "akuo 😀 akuo")
        XCTAssertEqual(f.rangeWrites.last, TextRange(location: 10, length: 0), "the caret is put back")
    }

    @TextActor func testPiecesBeforeTheEmojiAreUnaffectedByTheDrift() async {
        // The drift starts only after the emoji: pieces before it select exactly what they should.
        let f = field("akuo akuo 😀")
        f.hidden = 10..<12
        f.setRangeDrifts = true
        // Both pieces lie before the emoji: no drift, both convert.
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום 😀")
    }

    @TextActor func testSlackWholeStringForRangeFailureDoesNotBlock() async {
        // Slack answers -25212 for the whole box; the prefix check then just can't run.
        let f = field("akuo")
        f.stringForRangeFailsAtEnd = true
        let r = await run(f)
        XCTAssertEqual(r, .converted(pieces: 1))
    }

    // MARK: - Line breaks and selections

    @TextActor func testLineBreaksAreNeverTyped() async {
        let f = field("akuo\nakuo")
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום\nשלום")
        XCTAssertFalse(poster.typed.contains("\n"))
        XCTAssertFalse(poster.events.contains { $0.keyCode == KeyCode.returnKey })
    }

    @TextActor func testSelectionOverTwoLinesKeepsItsLineBreak() async {
        // P3-40 (b): Chromium's AXSelectedText drops the line break; the value keeps it, the pieces skip it.
        let f = field("ok akuo\nakuo ok", selection: 3..<12)
        f.selectedTextDropsLineBreaks = true
        let result = await run(f, .selection)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "ok שלום\nשלום ok", "only the selection converted, its line break kept")
        XCTAssertEqual(f.range(.selectedTextRange), .success(TextRange(location: 12, length: 0)))
    }

    @TextActor func testSelectionWhoseRangeTextDisagreesIsRefused() async {
        let f = field("akuo akuo", selection: 0..<4)
        f.stringForRangeOverride = "xxxx"
        let r = await run(f, .selection)
        XCTAssertEqual(r, .unavailable(.inconsistent))
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testBoxConvertWithASelectionNowRefuses() async {
        let f = field("akuo", selection: 0..<2)
        let r = await run(f, .box)
        XCTAssertEqual(r, .unavailable(.inconsistent))
    }

    // MARK: - Reads that can't be trusted → fall back

    @TextActor func testNotWebContentFallsBack() async {
        let f = field("akuo")
        f.webContent = false   // the omnibox
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.notWebContent))
        XCTAssertTrue(f.rangeWrites.isEmpty)
    }

    @TextActor func testLengthMismatchFallsBack() async {
        let f = field("akuo")
        f.numberOfCharactersOverride = 5
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.inconsistent))
    }

    @TextActor func testValueReadFailureFallsBack() async {
        let f = field("akuo")
        f.valueFails = true
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.readFailed))
    }

    @TextActor func testPrefixThatDisagreesFallsBack() async {
        let f = field("akuo", caret: 2)
        f.stringForRangeOverride = "zz"
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.inconsistent))
    }

    @TextActor func testOverTheCapFallsBack() async {
        let f = field(String(repeating: "a", count: ReplacementPlanner.maxFieldReadChars + 1))
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.boxSize))
    }

    @TextActor func testFocusOnAnotherElementAtStart() async {
        let f = field("akuo")
        let other = field("x")
        let r = await run(f, provider: SwitchableFocusProvider(other))
        XCTAssertEqual(r, .unavailable(.focusChanged))
    }

    @TextActor func testRefusedClaimWritesNothing() async {
        let f = field("akuo")
        let r = await run(f, claim: false)
        XCTAssertEqual(r, .abandoned)
        XCTAssertTrue(f.rangeWrites.isEmpty)
    }

    @TextActor func testNothingToConvert() async {
        let f = field("123 456")
        let r = await run(f)
        XCTAssertEqual(r, .nothingToConvert)
        XCTAssertTrue(f.rangeWrites.isEmpty)
    }

    // MARK: - Budget, focus, timing between pieces

    @TextActor func testBudgetRunsOutBetweenPiecesStopsWithTheWrittenPieceVerified() async {
        let f = field("akuo akuo")
        let clock = self.clock!
        f.onSetRange = { r in if !r.isCaret { clock.advance(byMilliseconds: 450) } }
        let result = await run(f)
        XCTAssertEqual(result, .partial(written: 1, .timedOut))
        XCTAssertEqual(f.text, "akuo שלום", "the last piece was written and verified, the first never started")
        XCTAssertEqual(f.range(.selectedTextRange), .success(TextRange(location: 9, length: 0)))
    }

    @TextActor func testBudgetGoneBeforeTheFirstPieceTypesNothing() async {
        let f = field("akuo")
        let clock = self.clock!
        let result = await sut(SwitchableFocusProvider(f)).run(.box, expected: f, plan: { read in
            clock.advance(byMilliseconds: 500)
            return self.boxPlan(read)
        }, mayWrite: { true })
        XCTAssertEqual(result, .unavailable(.timedOut))
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testFocusChangeBetweenPiecesStops() async {
        let f = field("akuo akuo")
        let provider = SwitchableFocusProvider(f)
        let other = field("x")
        var sets = 0
        f.onSetRange = { r in
            if !r.isCaret { sets += 1 }
            if sets == 1 { provider.focused = other }
        }
        let result = await run(f, provider: provider)
        XCTAssertEqual(result, .partial(written: 1, .focusChanged))
        XCTAssertEqual(f.text, "akuo שלום")
    }

    @TextActor func testASelectionThatShowsLateIsWaitedFor() async {
        // Chromium applies the range in the renderer: the first reads still show the caret.
        let f = field("akuo akuo")
        f.staleRangeReadsAfterSet = 3
        let r = await run(f)
        XCTAssertEqual(r, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום")
    }

    @TextActor func testASelectionThatNeverShowsTypesNothing() async {
        let f = field("akuo")
        f.staleRangeReadsAfterSet = 10_000
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.selectionMismatch))
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testKeysThatLandLateAreWaitedFor() async {
        let f = field("akuo akuo")
        f.keyLagNanos = 30_000_000
        let r = await run(f)
        XCTAssertEqual(r, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום")
    }

    @TextActor func testKeysThatNeverLandStopWithoutMovingTheSelection() async {
        let f = field("akuo akuo")
        f.keyLagNanos = nil
        let result = await run(f)
        XCTAssertEqual(result, .failed(written: 0, .notSettled))
        XCTAssertEqual(f.rangeWrites, [TextRange(location: 5, length: 4)], "no caret set after the typed keys")
    }

    @TextActor func testPostFailingAtTheFirstEventPutsTheCaretBack() async {
        let f = field("akuo")
        poster.failFrom = 0
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.postFailed))
        XCTAssertEqual(f.rangeWrites.last, TextRange(location: 4, length: 0))
    }

    @TextActor func testSecondConvertGoesBackToTheOtherLanguage() async {
        // P3-40: a second double-Shift converts again (no undo).
        let f = field("akuo")
        let r = await run(f)
        XCTAssertEqual(r, .converted(pieces: 1))
        XCTAssertEqual(f.text, "שלום")
        let again = await run(f)
        XCTAssertEqual(again, .converted(pieces: 1))
        XCTAssertEqual(f.text, "akuo")
    }

    // MARK: - Pure helpers

    func testPiecesJoinNeighboursAndSplitAtTheCaret() {
        let text = "abcd ef"
        let c = [TextChange(offset: 0, length: 1, text: "x"), TextChange(offset: 1, length: 1, text: "y"),
                 TextChange(offset: 2, length: 1, text: "z"), TextChange(offset: 5, length: 1, text: "w")]
        let p = ChromiumAXConvert.pieces(c, in: text, splittingAt: 2)
        XCTAssertEqual(p, [.init(location: 0, original: "ab", replacement: "xy"),
                           .init(location: 2, original: "c", replacement: "z"),
                           .init(location: 5, original: "e", replacement: "w")])
    }

    func testPiecesRefuseOverlaps() {
        let c = [TextChange(offset: 1, length: 2, text: "x"), TextChange(offset: 2, length: 1, text: "y")]
        XCTAssertEqual(ChromiumAXConvert.pieces(c, in: "abcd", splittingAt: 4), [])
    }

    func testJoinAcrossSpacesNeverAcrossALineBreakOrTheCaret() {
        let text = "ab cd\nef gh"
        let p: [ChromiumAXConvert.Piece] = [.init(location: 0, original: "ab", replacement: "12"),
                                            .init(location: 3, original: "cd", replacement: "34"),
                                            .init(location: 6, original: "ef", replacement: "56"),
                                            .init(location: 9, original: "gh", replacement: "78")]
        let joined = ChromiumAXConvert.joinedAcrossSpaces(p, in: text, splittingAt: 9)
        XCTAssertEqual(joined, [.init(location: 0, original: "ab cd", replacement: "12 34"),
                                .init(location: 6, original: "ef", replacement: "56"),
                                .init(location: 9, original: "gh", replacement: "78")])
    }

    @TextActor func testTooManyPiecesOnSeparateLinesFallBack() async {
        let line = "akuo"
        let f = field(Array(repeating: line, count: ChromiumAXConvert.maxPieces + 1).joined(separator: "\n"))
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.tooManyPieces))
        XCTAssertTrue(f.rangeWrites.isEmpty)
    }

    @TextActor func testManyWordsOnOneLineAreJoinedAndConvert() async {
        let f = field(Array(repeating: "akuo", count: ChromiumAXConvert.maxPieces + 1).joined(separator: " "))
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 1))
        XCTAssertEqual(f.text, Array(repeating: "שלום", count: ChromiumAXConvert.maxPieces + 1).joined(separator: " "))
    }

    func testInvalidPieceWithALineBreakIsRefused() {
        let p = [ChromiumAXConvert.Piece(location: 0, original: "a\nb", replacement: "x\ny")]
        XCTAssertFalse(ChromiumAXConvert.isValid(p, in: "a\nb", source: .box, selection: TextRange(location: 3, length: 0)))
    }

    func testCaretAfterCountsOnlyPiecesBeforeIt() {
        let p: [ChromiumAXConvert.Piece] = [.init(location: 0, original: "ab", replacement: "xyz"),
                                            .init(location: 5, original: "c", replacement: "")]
        XCTAssertEqual(ChromiumAXConvert.caret(after: p, anchor: 3), 4)
    }
}
