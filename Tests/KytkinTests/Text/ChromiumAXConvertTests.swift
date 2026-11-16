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
        // P3-42 QA: "akuo" occurs twice: the last one's unique window ("ום akuo") is checked first.
        XCTAssertEqual(f.rangeWrites, [TextRange(location: 8, length: 6), TextRange(location: 10, length: 4),
                                       TextRange(location: 0, length: 4), TextRange(location: 4, length: 0)])
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

    @TextActor func testEmojiOffsetDriftIsFoundByReadBackAndConverts() async {
        // Slack: offsets after the emoji land one emoji early when the range is set (P3-42 fell back here, P3-44 owner
        // test). P3-44: the unique window "  akuo" reads back short ("  ak", the emoji ate two units), so it is widened
        // by two, then reads back exactly; the piece is found inside it two units on, by an exact read-back. The emoji
        // stays, both words convert, the caret ends at the very end (after the emoji's units are counted).
        let f = field("akuo 😀 akuo")
        f.hidden = 5..<7
        f.setRangeDrifts = true
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום 😀 שלום")
        XCTAssertEqual(poster.typed, "שלוםשלום")
        XCTAssertEqual(f.rangeWrites.last, TextRange(location: 12, length: 0), "caret at the page's end")
    }

    @TextActor func testEmojiDriftWithAPageUnitCaretConverts() async {
        // P3-44 shape B: the app reads *and* writes page units, so the caret at the end reads past the end of AXValue
        // (by the emoji's two units). The read goes on (caret = the value's end), the shift search starts at 2.
        let f = field("vh 😀 vh vh")
        f.hidden = 3..<5
        f.setRangeDrifts = true
        f.readsInPageUnits = true
        let ax = sut(SwitchableFocusProvider(f))
        let result = await ax.run(.box, expected: f, plan: { self.boxPlan($0) }, mayWrite: { true })
        XCTAssertEqual(result, .converted(pieces: 3))
        XCTAssertEqual(f.text, "הי 😀 הי הי", "every vh once, the emoji kept")
        XCTAssertEqual(ax.lastDiagnostic.caretPastValue, 2)
        XCTAssertEqual(ax.lastDiagnostic.readSpace, .page)
        XCTAssertEqual(f.rangeWrites.last, TextRange(location: 11, length: 0), "caret back at the end, page units")
    }

    @TextActor func testOwnersSlackBoxBoldMentionEmojiTwoLines() async {
        // P3-44 owner test: line 1 bold "שלום" + mention pill "@Hillel Banai" (AX shows it as its own element) + 😂
        // (missing from AXValue, drifting the range writes); line 2 "akuo vh" typed on EN. Only line 2 converts; the
        // bold, the mention and the emoji stay; nothing is typed into line 1.
        let f = field("שלום @Hillel Banai 😂\nakuo vh", bold: 0..<4)
        f.hidden = 19..<21
        f.setRangeDrifts = true
        f.inlineAtoms = ["@Hillel Banai"]
        let ax = sut(SwitchableFocusProvider(f))
        let result = await ax.run(.box, expected: f, plan: { read in
            let w = FieldWindow(text: read.text, location: 0, caret: read.selection.location, reachesFieldStart: true,
                                reachesFieldEnd: true)
            guard case .convert(let p) = BoxConversion.plan(w, classify: self.layouts.runClass,
                                                             atomicTexts: read.atoms, convert: { side, g in
                self.layouts.converter(from: self.layouts.source(of: side))?.convert(g).text ?? g
            }) else { return .nothing }
            return .changes(p.changes)
        }, mayWrite: { true })
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום @Hillel Banai 😂\nשלום הי")
        XCTAssertEqual(f.boldText, "שלום")
        XCTAssertEqual(poster.typed, "הישלום", "only line 2's two words, last first")
        XCTAssertEqual(ax.lastDiagnostic.atoms, 1)
        XCTAssertEqual(ax.lastDiagnostic.maxShift, 2)
    }

    @TextActor func testShiftCandidates() async {
        XCTAssertEqual(ChromiumAXConvert.shiftCandidates(hint: 2, upper: 4), [2, 1, 0, 3, 4])
        XCTAssertEqual(ChromiumAXConvert.shiftCandidates(hint: 0, upper: 0), [0])
        XCTAssertEqual(ChromiumAXConvert.shiftCandidates(hint: 9, upper: 3), [3, 2, 1, 0])
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
        // P3-42 QA: the budget is gone while the first piece's selection is being checked: it is never typed.
        let f = field("akuo vh")
        let clock = self.clock!
        var sets = 0
        f.onSetRange = { r in
            if !r.isCaret { sets += 1 }
            if sets == 2, !r.isCaret { clock.advance(byMilliseconds: 450) }
        }
        let result = await run(f)
        XCTAssertEqual(result, .partial(written: 1, .timedOut))
        XCTAssertEqual(f.text, "akuo הי", "the last piece was written and verified, the first never typed")
        XCTAssertEqual(f.range(.selectedTextRange), .success(TextRange(location: 7, length: 0)))
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

    @TextActor func testStaleTreeAfterAWidenedWindowNeverTypesOverTheEmoji() async {
        // P3-44 QA: shape A (value-unit reads, drifted writes), the emoji right before the only piece. The widened window
        // (emoji + "akuo") reads back as the value range (2, 4) = the piece's own range. The next try selects the piece
        // at shift 0 (DOM: emoji + "ak"); Chromium's AX tree is still the old one for a read, so the range *and* the text
        // still say (2, 4) / "akuo". Accepting that stale read typed over the emoji. Now the selection is first moved
        // to a caret, so a stale read can't look like the new selection: the emoji survives and "akuo" converts.
        let f = field("x 😀akuo")
        f.hidden = 2..<4
        f.setRangeDrifts = true
        f.staleRangeReadsAfterSet = 1
        f.staleSelectedTextToo = true
        let result = await sut(SwitchableFocusProvider(f)).run(.box, expected: f, plan: { _ in
            .changes([TextChange(offset: 2, length: 4, text: "שלום")])
        }, mayWrite: { true })
        XCTAssertTrue(f.text.contains("😀"), "the emoji is never typed over")
        XCTAssertEqual(result, .converted(pieces: 1))
        XCTAssertEqual(f.text, "x 😀שלום")
    }

    @TextActor func testASelectionThatNeverShowsTypesNothing() async {
        let f = field("akuo")
        f.staleRangeReadsAfterSet = 10_000
        let r = await run(f)
        XCTAssertEqual(r, .unavailable(.selectionNotShown), "P3-44: told apart from a mismatch for the DEBUG log")
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
        // P3-42 QA: the repeated word's unique window is selected and read back first.
        XCTAssertEqual(f.rangeWrites, [TextRange(location: 3, length: 6), TextRange(location: 5, length: 4)],
                       "no caret set after the typed keys")
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

    // MARK: - P3-42 QA: a drifted selection on another occurrence of the same text

    @TextActor func testDriftOntoAnotherOccurrenceOfTheSameTextConvertsTheRightOne() async {
        // P3-42 QA: Slack's emoji shifts every offset by two units, and the range reads back drifted the same way, so the
        // range "agrees". "a a a" repeats with that period: the piece (the last "a") selects the middle "a", whose text
        // agrees too. The unique window around it ("a a a", the whole box) reads back as "a a", so the middle "a" is
        // never typed over. P3-44: the shift search then finds the window two units on, and the *last* "a" converts.
        let f = field("😀a a a")
        f.hidden = 0..<2
        f.setRangeDrifts = true
        f.rangeReadEchoesWrite = true
        let result = await sut(SwitchableFocusProvider(f)).run(.box, expected: f, plan: { _ in
            .changes([TextChange(offset: 4, length: 1, text: "ש")])
        }, mayWrite: { true })
        XCTAssertEqual(result, .converted(pieces: 1))
        XCTAssertEqual(f.text, "😀a a ש", "the last a, never the middle one")
    }

    @TextActor func testRepeatedWordWithoutDriftStillConvertsThroughItsWindow() async {
        // P3-42 QA: the same word twice, no drift: the window around the second one is selected and read back first,
        // then the piece itself.
        let f = field("akuo akuo")
        let result = await run(f)
        XCTAssertEqual(result, .converted(pieces: 2))
        XCTAssertEqual(f.text, "שלום שלום")
        XCTAssertEqual(f.rangeWrites, [TextRange(location: 3, length: 6), TextRange(location: 5, length: 4),
                                       TextRange(location: 0, length: 4), TextRange(location: 9, length: 0)])
    }

    @TextActor func testBudgetSpentWaitingForTheSelectionPostsNoKeys() async {
        // P3-42 QA: the selection shows only after the budget is gone: no key is posted (it could race the hold-back
        // flush), the caret goes back.
        let f = field("akuo")
        let clock = self.clock!
        f.onSetRange = { r in if !r.isCaret { clock.advance(byMilliseconds: 450) } }
        let result = await run(f)
        XCTAssertEqual(result, .unavailable(.timedOut))
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(f.text, "akuo")
        XCTAssertEqual(f.rangeWrites.last, TextRange(location: 4, length: 0))
    }

    func testAnchorWindow() {
        func w(_ s: String, _ loc: Int, _ len: Int) -> TextRange? {
            ChromiumAXConvert.anchorWindow(for: TextRange(location: loc, length: len), in: Array(s.utf16))
        }
        XCTAssertEqual(w("akuo vh", 0, 4), TextRange(location: 0, length: 4), "unique: the piece itself")
        XCTAssertEqual(w("akuo akuo", 5, 4), TextRange(location: 3, length: 6))
        XCTAssertEqual(w("a a a", 4, 1), TextRange(location: 0, length: 5), "the whole box, always unique")
        XCTAssertEqual(w("x😀ab x😀ab", 10, 1), TextRange(location: 1, length: 10), "never splits a surrogate pair")
        XCTAssertNil(w("", 0, 0))
        XCTAssertNil(w("ab", 1, 5))
        XCTAssertTrue(ChromiumAXConvert.occursOnce(Array("ab".utf16)[...], in: Array("xaby".utf16)))
        XCTAssertFalse(ChromiumAXConvert.occursOnce(Array("ab".utf16)[...], in: Array("abab".utf16)))
    }
}
