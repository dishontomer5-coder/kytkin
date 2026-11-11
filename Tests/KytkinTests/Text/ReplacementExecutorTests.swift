// P2-18: ReplacementExecutor (TextReplacer's logic) against fake AX and key-posting seams: focus reading,
// the secure/IME refusals, AX write + read-back, typing, grapheme-correct backspaces, the control-character
// guard, and the `ours` marker on every posted event.

import XCTest

final class ReplacementExecutorTests: XCTestCase {
    private var field: FakeTextField!
    private var provider: FakeFocusProvider!
    private var poster: RecordingPoster!

    @TextActor private func makeExecutor(_ f: FakeTextField) -> ReplacementExecutor {
        field = f
        provider = FakeFocusProvider(f)
        poster = RecordingPoster()
        return ReplacementExecutor(focusProvider: provider, poster: poster)
    }

    private func sel(_ location: Int, _ length: Int) -> TextRange { TextRange(location: location, length: length) }

    // MARK: - Focus

    @TextActor func testFocusInfoReadsAPlainField() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        let info = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(info, FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                       selTextSettable: true, selRangeSettable: true, selection: "akuo",
                                       canReadBeforeCaret: false))
        XCTAssertEqual(provider.timeouts, [0.25])
    }

    @TextActor func testFocusInfoCaretCanReadBeforeCaret() async {
        let x = makeExecutor(FakeTextField("hello akuo"))
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.canReadBeforeCaret, true)
        field.supportsStringForRangeValue = false
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.canReadBeforeCaret, false)
    }

    @TextActor func testSecureRoleIsReportedAndNothingElseIsRead() async {
        let f = FakeTextField("secret", selection: sel(0, 6))
        f.role = FocusInfo.secureTextFieldRole
        let x = makeExecutor(f)
        let info = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(info?.isSecure, true)
        XCTAssertNil(info?.selection)
        XCTAssertFalse(f.reads.contains(.selectedText), "never read text from a password field")
    }

    @TextActor func testSecureSubroleIsSecure() async {
        let f = FakeTextField("secret", selection: sel(0, 6))
        f.role = "AXTextField"
        f.subrole = FocusInfo.secureTextFieldRole
        let x = makeExecutor(f)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.isSecure, true)
        XCTAssertFalse(f.reads.contains(.selectedText))
    }

    @TextActor func testCocoaMarkedTextIsComposing() async {
        let f = FakeTextField("nihon", selection: sel(5, 0))
        f.markedRange = sel(0, 5)
        let x = makeExecutor(f)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.hasMarkedText, true)
        f.markedRange = sel(5, 0)   // an empty marked range is no composition
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.hasMarkedText, false)
    }

    @TextActor func testWebKitMarkedTextIsComposing() async {
        let f = FakeTextField("x")
        f.webKitMarked = .success("に")
        let x = makeExecutor(f)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.hasMarkedText, true)
        f.webKitMarked = .success("")
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.hasMarkedText, false)
        // Present but unreadable: a composition can't be ruled out.
        f.webKitMarked = .failure(.failed)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.hasMarkedText, true)
    }

    @TextActor func testTimeoutsMakeFocusUnknown() async {
        for attribute in [AXTextAttribute.role, .subrole, .markedTextRange, .webKitMarkedText, .selectedText,
                          .selectedTextRange] {
            let f = FakeTextField("hello akuo", selection: sel(6, 4))
            f.timeouts = [attribute]
            let x = makeExecutor(f)
            XCTAssertNil(x.focusInfo(timeout: 0.25), "\(attribute) timing out must refuse, not guess")
            XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
            XCTAssertTrue(poster.events.isEmpty)
        }
    }

    @TextActor func testNoElementOrNoPermissionOrNoRoleIsUnknown() async {
        _ = makeExecutor(FakeTextField("x"))
        for error in [AXAccessError.notTrusted, .noValue, .timeout] {
            let x = ReplacementExecutor(focusProvider: FakeFocusProvider(error: error), poster: poster)
            XCTAssertNil(x.focusInfo(timeout: 0.25))
        }
        let f = FakeTextField("x")
        f.role = nil
        XCTAssertNil(makeExecutor(f).focusInfo(timeout: 0.25))
    }

    @TextActor func testGarbageSelectedRangeIsNotSettable() async {
        let f = FakeTextField("hello", selection: sel(5, 0))
        f.reportedRange = sel(5, 4_294_967_292)   // R5: WebKit before a range was set
        let x = makeExecutor(f)
        let info = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(info?.selRangeSettable, false)
        XCTAssertEqual(info?.canReadBeforeCaret, false)
    }

    // MARK: - Steps need a safe focus

    @TextActor func testNoStepRunsWithoutFocusInfo() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        for step in [ReplacementStep.axWriteSelection(verify: true), .typeOverSelection, .backspaceAndType(count: 4),
                     .axReadRunBeforeCaret(maxChars: 64)] {
            XCTAssertEqual(x.perform(step, old: "akuo", new: "שלום"), .unavailable)
        }
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(field.writes.isEmpty)
    }

    @TextActor func testSecureOrComposingFocusBlocksEveryStep() async {
        let secure = FakeTextField("akuo", selection: sel(0, 4))
        secure.role = FocusInfo.secureTextFieldRole
        let composing = FakeTextField("akuo", selection: sel(0, 4))
        composing.markedRange = sel(0, 4)
        for f in [secure, composing] {
            let x = makeExecutor(f)
            _ = x.focusInfo(timeout: 0.25)
            for step in [ReplacementStep.axWriteSelection(verify: true), .typeOverSelection,
                         .backspaceAndType(count: 4), .axReadRunBeforeCaret(maxChars: 64)] {
                XCTAssertEqual(x.perform(step, old: "akuo", new: "שלום"), .unavailable)
            }
            XCTAssertTrue(poster.events.isEmpty)
            XCTAssertTrue(f.writes.isEmpty)
        }
    }

    @TextActor func testEndReplacementDropsTheFocus() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        x.endReplacement()
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - AX write + read-back

    @TextActor func testAXWriteVerifies() async {
        let x = makeExecutor(FakeTextField("hello akuo world", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .done)
        XCTAssertEqual(field.text, "hello שלום world")
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testAXWriteReadsBackThroughValueWithoutStringForRange() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.supportsStringForRangeValue = false
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .done)
    }

    @TextActor func testSilentNoopWriteFailsVerifyWithFieldUntouched() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.writeBehavior = .silentNoop
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"),
                       StepOutcome(verdict: .failedVerify, fieldUntouched: true))
        XCTAssertEqual(f.text, "hello akuo")
    }

    @TextActor func testGarbledWriteFailsVerifyAndIsNotUntouched() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.writeBehavior = .garble
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"),
                       StepOutcome(verdict: .failedVerify, fieldUntouched: false))
    }

    @TextActor func testFailedWriteIsUnavailableAndUntouched() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.writeBehavior = .fails
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
    }

    @TextActor func testAXWriteRefusesWhenTheSelectionChanged() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.selection = sel(0, 5)   // the user selected something else
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertFalse(f.writes.contains(.selectedText))
    }

    @TextActor func testAXWriteRefusesWhenNotSettable() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.selTextSettable = false
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(f.writes.isEmpty)
    }

    // MARK: - Typing

    @TextActor func testTypeOverPostsMarkedUnicodeWithClearedFlags() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .done)
        XCTAssertEqual(poster.typed, "שלום")
        XCTAssertEqual(poster.backspaceCount, 0)
        XCTAssertFalse(poster.events.isEmpty)
        for e in poster.events {
            XCTAssertEqual(e.marker, EventOrigin.oursMarker)
            XCTAssertEqual(e.marker, 0x4B59544B)
            XCTAssertEqual(e.modifierFlags, 0)
        }
    }

    @TextActor func testTypeOverNeverTypesAControlCharacter() async {
        let x = makeExecutor(FakeTextField("a\nb", selection: sel(0, 3)))
        _ = x.focusInfo(timeout: 0.25)
        // A selection holding a line break is never typed over (§12 T2), even if the planner were bypassed.
        XCTAssertEqual(x.perform(.typeOverSelection, old: "a\nb", new: "ש\nנ"), .unavailable)
        // And a replacement holding a control character is never typed.
        for bad in ["ש\tנ", "ש\rנ", "ש\u{2028}נ", "ש\u{2029}", "\u{1B}", "x\u{0}"] {
            XCTAssertEqual(x.perform(.typeOverSelection, old: "ab", new: bad), .unavailable)
            XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "ab", new: bad), .unavailable)
        }
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testBackspaceCountIsGraphemes() async {
        let x = makeExecutor(FakeTextField("hello"))
        _ = x.focusInfo(timeout: 0.25)
        // Hebrew with niqqud: ש + shin dot + qamats is one grapheme, ו + holam is one. 4 graphemes, 8 scalars.
        let niqqud = "שָׁלוֹם"
        XCTAssertEqual(niqqud.count, 4)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 4), old: niqqud, new: "akuo"), .done)
        XCTAssertEqual(poster.backspaceCount, 4)
        XCTAssertEqual(poster.typed, "akuo")
    }

    @TextActor func testBackspaceCountWithEmoji() async {
        let x = makeExecutor(FakeTextField("hello"))
        _ = x.focusInfo(timeout: 0.25)
        let old = "👍🏽👨‍👩‍👧a"   // skin-tone modifier and a ZWJ family: 3 graphemes, 13 UTF-16 units
        XCTAssertEqual(old.count, 3)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 3), old: old, new: "ש"), .done)
        XCTAssertEqual(poster.backspaceCount, 3)
        XCTAssertEqual(poster.events.count, 3 * 2 + 2)
        // Backspaces come first, then the text.
        XCTAssertTrue(poster.events.prefix(6).allSatisfy { $0.keyCode == KeyCode.delete && $0.unicode.isEmpty })
    }

    @TextActor func testBackspaceCountMismatchWithOldIsRefused() async {
        let x = makeExecutor(FakeTextField("hello"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 5), old: "שָׁלוֹם", new: "akuo"), .unavailable)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 0), old: "", new: "akuo"), .unavailable)
        XCTAssertEqual(x.perform(.backspaceAndType(count: KeyStrokeComposer.maxBackspaces + 1), old: "", new: "a"),
                       .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testPosterFailureMidwayIsNotUntouched() async {
        let x = makeExecutor(FakeTextField("hello"))
        _ = x.focusInfo(timeout: 0.25)
        poster.failFrom = 0
        XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "ab", new: "שנ"), .unavailable)
        poster.failFrom = 3
        XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "ab", new: "שנ"),
                       StepOutcome(verdict: .unavailable, fieldUntouched: false))
    }

    @TextActor func testPasteAndKeyCodesAreNotInTheMVP() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.pasteboard, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(x.perform(.keyCodesAfterSwitch, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - Run read before the caret (P2-59, 001 §12.3 X4)

    /// The real scan over the ABC / Apple Hebrew fixtures.
    private let scan: (BeforeCaretWindow) -> RunLocation? = { w in
        if case .run(let loc, _) = RunBeforeCaret.scan(w, classify: ConvertFixtures.layouts.runClass) { return loc }
        return nil
    }

    @TextActor func testRunReadFindsTheRunAndTheWriteTargetsIt() async {
        let x = makeExecutor(FakeTextField("שלום ,usv"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan),
                       StepOutcome(verdict: .done, fieldUntouched: true))
        XCTAssertEqual(x.wordBeforeCaret, ",usv")
        XCTAssertTrue(field.writes.isEmpty, "the read writes nothing")
        XCTAssertEqual(field.stringRangesRead, [sel(0, 9)], "one AXStringForRange read of the window")
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: ",usv", new: "תודה"), .done)
        XCTAssertEqual(field.text, "שלום תודה")
        XCTAssertEqual(field.selection, sel(9, 0), "success: the caret after the new text")
    }

    @TextActor func testPerformOnTheRunReadIsUnavailable() async {
        let x = makeExecutor(FakeTextField("akuo"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axReadRunBeforeCaret(maxChars: 256), old: "", new: ""), .unavailable)
        XCTAssertTrue(field.stringRangesRead.isEmpty)
    }

    @TextActor func testRunReadWindowIsAtMostMaxCharsAndReachesTheFieldStartOnlyAtZero() async {
        let text = String(repeating: "x", count: 300) + " akuo"   // 305 units, caret at the end
        let x = makeExecutor(FakeTextField(text))
        _ = x.focusInfo(timeout: 0.25)
        var seen: BeforeCaretWindow?
        _ = x.readRunBeforeCaret(maxChars: 256) { seen = $0; return nil }
        XCTAssertEqual(field.stringRangesRead, [sel(49, 256)])
        XCTAssertEqual(seen?.location, 49)
        XCTAssertEqual(seen?.text.utf16.count, 256)
        XCTAssertEqual(seen?.reachesFieldStart, false)

        let y = makeExecutor(FakeTextField("akuo"))
        _ = y.focusInfo(timeout: 0.25)
        _ = y.readRunBeforeCaret(maxChars: 256) { seen = $0; return nil }
        XCTAssertEqual(seen, BeforeCaretWindow(text: "akuo", location: 0, reachesFieldStart: true))
    }

    /// P3-33: a run across line breaks is read and written back whole; the line breaks stay where they were.
    @TextActor func testMultiLineRunIsReadAndWrittenThroughAX() async {
        let x = makeExecutor(FakeTextField("שלום\nakuo\nvh nhv"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars, locate: scan).verdict, .done)
        XCTAssertEqual(x.wordBeforeCaret, "akuo\nvh nhv")
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo\nvh nhv", new: "שלום\nהי מיה"), .done)
        XCTAssertEqual(field.text, "שלום\nשלום\nהי מיה")
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// P3-33 QA: the 4,096-unit cut can land inside an emoji (a surrogate pair). The cut word is dropped (X1 step 6),
    /// the run starts at the next whole word, and the AX write never touches the emoji or the word glued to it.
    @TextActor func testTheFullWindowCutInsideAnEmojiNeverTouchesIt() async {
        let head = "q\u{1F600}akuo "                                    // 8 units; the window starts at unit 2
        let body = String(repeating: "akuo ", count: 818)               // 4,090 units
        let f = FakeTextField(head + body)
        XCTAssertEqual(f.units.count, 2 + ReplacementPlanner.maxRunReadChars)
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars, locate: scan).verdict, .done)
        XCTAssertEqual(field.stringRangesRead, [sel(2, ReplacementPlanner.maxRunReadChars)], "one read, no retry")
        XCTAssertEqual(x.wordBeforeCaret, body)
        let new = ConvertFixtures.layouts.converter(from: IDs.abc)!.convert(body).text
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: body, new: new), .done)
        XCTAssertEqual(field.text, head + new, "the emoji and the cut word before the run are unchanged")
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// P3-33 QA: CRLF is one grapheme but two UTF-16 units; the run's range, the write and the read-back all count it
    /// as two, so nothing before the run is overwritten and nothing after the caret is left behind.
    @TextActor func testACRLFRunIsCountedInUnitsEndToEnd() async {
        let x = makeExecutor(FakeTextField("\u{05E9}\u{05DC}\u{05D5}\u{05DD}\r\nakuo\r\nvh"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars, locate: scan).verdict, .done)
        XCTAssertEqual(x.wordBeforeCaret, "akuo\r\nvh")
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo\r\nvh", new: "XYZW\r\nQR"), .done)
        XCTAssertEqual(field.text, "\u{05E9}\u{05DC}\u{05D5}\u{05DD}\r\nXYZW\r\nQR")
        XCTAssertEqual(field.selection, sel(field.units.count, 0), "the caret is back at the end")
    }

    /// P3-33: a run holding a tab (or any non-line-break control) is never handed on, even if a locator returned it.
    @TextActor func testRunWithATabIsUnavailable() async {
        let x = makeExecutor(FakeTextField("akuo\tvh"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256) { _ in RunLocation(offset: 0, length: 7) }, .unavailable)
        XCTAssertNil(x.wordBeforeCaret)
    }

    /// P3-33: a big window that comes back the wrong length is retried smaller, nearest the caret, so the AX path
    /// still converts the tail it can read instead of giving up (and falling back to the buffer's few words).
    @TextActor func testWrongLengthReadIsRetriedWithSmallerWindows() async {
        let text = String(repeating: "akuo ", count: 400) + "vh"         // 2,002 units
        let f = FakeTextField(text)
        f.stringForRangeExactUpTo = 300
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        var seen: BeforeCaretWindow?
        let out = x.readRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars) { w in seen = w; return nil }
        XCTAssertEqual(out.verdict, .done)
        XCTAssertEqual(field.stringRangesRead, [sel(0, 2002), sel(978, 1024), sel(1746, 256)])
        XCTAssertEqual(seen?.location, 1746)
        XCTAssertEqual(seen?.reachesFieldStart, false)
    }

    @TextActor func testEveryWindowWrongIsUnavailable() async {
        let f = FakeTextField(String(repeating: "akuo ", count: 400) + "vh")
        f.stringForRangeExactUpTo = 100
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars, locate: scan), .unavailable)
        XCTAssertEqual(field.stringRangesRead.count, 3, "bounded: the window and two retries")
    }

    /// P3-33: WebKit's contenteditable turns a written no-break space into a plain space. That still verifies (a
    /// strict compare marked AX broken for the whole session, so every later convert fell back to the buffer).
    @TextActor func testReadBackAcceptsANoBreakSpaceThatLandsAsASpace() async {
        let f = FakeTextField("שלום\u{00A0}akuo\u{00A0}vh")
        f.writeBehavior = .noBreakSpacesBecomeSpaces
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan).verdict, .done)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo\u{00A0}vh", new: "שלום\u{00A0}הי"), .done)
        XCTAssertEqual(field.text, "שלום\u{00A0}שלום הי")
    }

    func testReadsBackAsAllowsOnlyWhitespaceSwaps() {
        XCTAssertTrue(ReplacementExecutor.readsBackAs("a b", "a\u{00A0}b"))
        XCTAssertTrue(ReplacementExecutor.readsBackAs("a\u{00A0}b", "a b"))
        XCTAssertTrue(ReplacementExecutor.readsBackAs("a\rb", "a\nb"))
        XCTAssertTrue(ReplacementExecutor.readsBackAs("a\u{2029}b", "a\nb"))
        XCTAssertFalse(ReplacementExecutor.readsBackAs("a b", "a\nb"), "a space is not a line break")
        XCTAssertFalse(ReplacementExecutor.readsBackAs("ab", "a b"))
        XCTAssertFalse(ReplacementExecutor.readsBackAs("a\r\nb", "a\nb"), "different lengths")
        XCTAssertFalse(ReplacementExecutor.readsBackAs("שלוס", "שלום"))
        // P3-33 QA: canonical equivalence verifies, as it did before P3-33 (the builder's strict scalar compare would
        // mark AX broken for an app that reorders combining marks). Hebrew dagesh + qamats in either order.
        XCTAssertTrue(ReplacementExecutor.readsBackAs("e\u{0301}", "\u{00E9}"))
        XCTAssertTrue(ReplacementExecutor.readsBackAs("\u{05D1}\u{05BC}\u{05B8}", "\u{05D1}\u{05B8}\u{05BC}"))
        XCTAssertFalse(ReplacementExecutor.readsBackAs("\u{05D1}\u{05B8}", "\u{05D1}\u{05BC}"), "a different mark")
    }

    @TextActor func testRunReadPendingRangeIsAbsolute() async {
        // The caret sits in the middle of the field; the run's range is absolute, not window-relative.
        let x = makeExecutor(FakeTextField("first line\nשלום akuo|tail", selection: sel(20, 0)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 8, locate: scan).verdict, .done)
        XCTAssertEqual(field.stringRangesRead, [sel(12, 8)])
        XCTAssertEqual(x.wordBeforeCaret, "akuo")
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .done)
        XCTAssertEqual(field.text, "first line\nשלום שלום|tail")
        XCTAssertEqual(field.selection, sel(20, 0))
    }

    @TextActor func testRunReadFindingNothingIsDoneWithoutARun() async {
        let x = makeExecutor(FakeTextField("akuo\t"))   // P3-33: a tab, since a line break no longer ends the run
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan),
                       StepOutcome(verdict: .done, fieldUntouched: true))
        XCTAssertNil(x.wordBeforeCaret)
        // Nothing found, so the next AX write has no range and works on the (empty) selection: refused.
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(field.text, "akuo\t")
    }

    @TextActor func testRunReadNeedsACaretAfterTheFieldStart() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan), .unavailable, "a selection, not a caret")
        XCTAssertNil(x.wordBeforeCaret)
        let y = makeExecutor(FakeTextField("akuo", selection: sel(0, 0)))
        _ = y.focusInfo(timeout: 0.25)
        XCTAssertEqual(y.readRunBeforeCaret(maxChars: 256, locate: scan), .unavailable, "caret at the field start")
    }

    @TextActor func testRunReadMustReturnExactlyTheWindow() async {
        let f = FakeTextField("שלום akuo")
        f.stringForRangeOverride = "akuo"   // the app answered fewer units than asked
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        var called = false
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256) { _ in called = true; return nil }, .unavailable)
        XCTAssertFalse(called)
        XCTAssertNil(x.wordBeforeCaret)
    }

    @TextActor func testRunReadTimeoutIsUnavailable() async {
        let f = FakeTextField("שלום akuo")
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.timeouts = [.selectedTextRange]
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan), .unavailable)
    }

    @TextActor func testRunReadRefusesARunThatDoesNotEndAtTheCaretOrSplitsAScalar() async {
        let x = makeExecutor(FakeTextField("😀akuo"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256) { _ in RunLocation(offset: 2, length: 2) }, .unavailable)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256) { _ in RunLocation(offset: 1, length: 5) }, .unavailable,
                       "starts inside the emoji's surrogate pair")
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256) { _ in RunLocation(offset: 6, length: 0) }, .unavailable)
        XCTAssertNil(x.wordBeforeCaret)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan).verdict, .done)
        XCTAssertEqual(x.wordBeforeCaret, "😀akuo", "an emoji inside the token passes through with it")
    }

    @TextActor func testRunReadNeedsASafeFocus() async {
        let x = makeExecutor(FakeTextField("akuo"))
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan), .unavailable, "no focusInfo yet")
        let secure = FakeTextField("akuo")
        secure.role = FocusInfo.secureTextFieldRole
        let y = makeExecutor(secure)
        _ = y.focusInfo(timeout: 0.25)
        XCTAssertEqual(y.readRunBeforeCaret(maxChars: 256, locate: scan), .unavailable)
        XCTAssertTrue(secure.stringRangesRead.isEmpty, "nothing is read from a password field")
    }

    // MARK: - Strict collapse (X4)

    @TextActor func testFailedRunWriteIsUntouchedOnlyWithTheCaretVerifiedBack() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .silentNoop
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        _ = x.readRunBeforeCaret(maxChars: 256, locate: scan)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"),
                       StepOutcome(verdict: .failedVerify, fieldUntouched: true))
        XCTAssertEqual(f.selection, sel(9, 0))
    }

    @TextActor func testUnverifiedCollapseCountsAsTouched() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .silentNoop
        f.rejectsCaretRanges = true
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        _ = x.readRunBeforeCaret(maxChars: 256, locate: scan)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"),
                       StepOutcome(verdict: .failedVerify, fieldUntouched: false))
        XCTAssertEqual(f.selection, sel(5, 4), "the run is still selected: no key may follow")
    }

    @TextActor func testStaleRangeGuardRestoresTheCaretAndStaysUntouched() async {
        let f = FakeTextField("שלום akuo")
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        _ = x.readRunBeforeCaret(maxChars: 256, locate: scan)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akux", new: "שלום"), .unavailable)
        XCTAssertEqual(f.selection, sel(9, 0))
        XCTAssertEqual(f.text, "שלום akuo")
    }
    // MARK: - P2-49 item 6: a failed subrole read counts as secure

    @TextActor func testFailedSubroleReadIsSecureAndNothingElseIsRead() async {
        let f = FakeTextField("secret", selection: sel(0, 6))
        f.role = "AXTextField"
        f.subroleResult = .failure(.failed)   // an AX error, or a value of the wrong type (adapter: `.failed`)
        let x = makeExecutor(f)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.isSecure, true)
        XCTAssertFalse(f.reads.contains(.selectedText), "nothing more is read from a field that may be a password")
        XCTAssertNil(x.focusedElement)
        for step in [ReplacementStep.axWriteSelection(verify: true), .typeOverSelection, .backspaceAndType(count: 6)] {
            XCTAssertEqual(x.perform(step, old: "secret", new: "שלום"), .unavailable)
        }
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testAbsentSubroleIsNotSecureButATimedOutOneIsUnknown() async {
        for absent in [AXAccessError.noValue, .unsupported] {
            let f = FakeTextField("akuo")
            f.subroleResult = .failure(absent)
            XCTAssertEqual(makeExecutor(f).focusInfo(timeout: 0.25)?.isSecure, false, "\(absent)")
        }
        for abort in [AXAccessError.timeout, .invalidElement, .notTrusted] {
            let f = FakeTextField("akuo")
            f.subroleResult = .failure(abort)
            XCTAssertNil(makeExecutor(f).focusInfo(timeout: 0.25), "\(abort)")
        }
        let f = FakeTextField("akuo")
        f.subroleResult = .success("AXSearchField")
        XCTAssertEqual(makeExecutor(f).focusInfo(timeout: 0.25)?.isSecure, false)
    }

    // MARK: - P2-49 item 3: the focus must not have moved before a key step

    @TextActor func testKeyStepsRefuseWhenTheFocusMovedToAnotherElement() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        let other = FakeTextField("chat message", selection: sel(0, 4))
        provider.result = .success(other)
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 4), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty, "keys would land in the other field")
        XCTAssertEqual(provider.timeouts, [0.25, 0.25, 0.25], "re-read with focusInfo's timeout before each key step")
    }

    @TextActor func testKeyStepsRunWhenTheFocusIsACopyOfTheSameElement() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        let copy = FakeTextField("hello akuo", selection: sel(6, 4))
        copy.elementID = field.elementID   // live: a fresh AXUIElement that is CFEqual to the first
        provider.result = .success(copy)
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .done)
        XCTAssertEqual(poster.typed, "שלום")
    }

    @TextActor func testKeyStepsRefuseWhenTheFocusCantBeReadAgain() async {
        for error in [AXAccessError.noValue, .notTrusted, .invalidElement, .failed, .timeout] {
            let x = makeExecutor(FakeTextField("hello"))
            _ = x.focusInfo(timeout: 0.25)
            provider.result = .failure(error)
            XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "lo", new: "שנ"), .unavailable, "\(error)")
            XCTAssertTrue(poster.events.isEmpty, "\(error)")
        }
    }

    // MARK: - P2-49 item 2: type-over re-reads the selection

    @TextActor func testTypeOverRefusesWhenTheSelectionBecameACaret() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.selection = sel(10, 0)   // dropped since focusInfo: typing would insert next to "akuo", not over it
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(f.text, "hello akuo")
    }

    @TextActor func testTypeOverRefusesWhenTheSelectionLengthChanged() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        for changed in [sel(6, 3), sel(0, 10), sel(5, 5)] {
            f.selection = changed
            XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable, "\(changed)")
        }
        XCTAssertTrue(poster.events.isEmpty)
        // Length is counted in UTF-16 units, as AX reports it: "👍a" is 3 units.
        let g = FakeTextField("x 👍a", selection: sel(2, 3))
        let y = makeExecutor(g)
        _ = y.focusInfo(timeout: 0.25)
        XCTAssertEqual(y.perform(.typeOverSelection, old: "👍a", new: "ש"), .done)
    }

    @TextActor func testTypeOverGoesAheadWhenTheRangeCantBeChecked() async {
        // R5: WebKit's garbage range (implausible): AX can't tell, so typing goes ahead as before P2-49.
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.reportedRange = sel(6, 4_294_967_292)
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .done)
    }

    @TextActor func testTypeOverRefusesWhenTheRangeReadTimesOut() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.timeouts = [.selectedTextRange]
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - P2-49 item 5: the first AX timeout ends the step (and the replacement's AX use)

    @TextActor func testAWriteThatTimesOutAsksTheAppNothingMoreAndIsNotUntouched() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        f.writeBehavior = .writesThenTimesOut
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        let out = x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום")
        XCTAssertEqual(out, StepOutcome(verdict: .unavailable, fieldUntouched: false), "the state is unknown: halt")
        XCTAssertEqual(f.callsAfterTimeout, 0, "no intact check, read-back or collapse after the timeout")
        // A later key step in the same replacement is refused without asking AX again (not even for the focus).
        let focusReads = provider.timeouts.count
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(provider.timeouts.count, focusReads)
        XCTAssertEqual(f.callsAfterTimeout, 0)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testATimedOutRunWriteNeverCollapsesOrReadsBack() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .timesOut
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 256, locate: scan).verdict, .done)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום").fieldUntouched, false)
        XCTAssertEqual(f.callsAfterTimeout, 0)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 4), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testATimeoutBeforeAnyWriteIsUntouchedButStillEndsAXUse() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.timeouts = [.selectedText]   // isSettable(selectedText) hangs
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(f.writes.isEmpty)
        let focusReads = provider.timeouts.count
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(provider.timeouts.count, focusReads, "a hung app costs one timeout, not one per step")
        XCTAssertEqual(f.callsAfterTimeout, 0)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testAFocusReCheckTimeoutLatches() async {
        let f = FakeTextField("hello")
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        provider.result = .failure(.timeout)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "lo", new: "שנ"), .unavailable)
        provider.result = .success(f)
        XCTAssertEqual(x.perform(.backspaceAndType(count: 2), old: "lo", new: "שנ"), .unavailable,
                       "still latched for this replacement")
        XCTAssertEqual(provider.timeouts.count, 2, "focusInfo + the one re-check that timed out")
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testTheLatchIsPerReplacement() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.timeouts = [.selectedText]
        _ = x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום")
        f.timeouts = []   // the app recovered
        XCTAssertNotNil(x.focusInfo(timeout: 0.25), "a new replacement starts with a fresh latch")
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .done)
    }

    // MARK: - QA P2-49: an unusable range falls back to the selected text

    @TextActor func testTypeOverWithAnUnusableRangeRefusesWhenTheSelectedTextChanged() async {
        // AX lies about (or won't give) the range, and the selection really changed: typing would insert twice.
        let unusable: [(String, (FakeTextField) -> Void)] = [
            ("garbage", { $0.reportedRange = TextRange(location: 6, length: 4_294_967_292) }),
            ("negative", { $0.reportedRange = TextRange(location: -1, length: 4) }),
            ("unsupported", { $0.selectedRangeError = .unsupported }),
            ("noValue", { $0.selectedRangeError = .noValue }),
            ("wrong type", { $0.selectedRangeError = .failed }),
        ]
        for (name, breakRange) in unusable {
            for changed in [sel(10, 0), sel(6, 3), sel(0, 4)] {
                let f = FakeTextField("hello akuo", selection: sel(6, 4))
                let x = makeExecutor(f)
                _ = x.focusInfo(timeout: 0.25)
                f.selection = changed
                breakRange(f)
                XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable,
                               "\(name) \(changed)")
                XCTAssertTrue(poster.events.isEmpty, "\(name) \(changed)")
            }
            // The selection is still "akuo": typing goes ahead, as before P2-49.
            let f = FakeTextField("hello akuo", selection: sel(6, 4))
            let x = makeExecutor(f)
            _ = x.focusInfo(timeout: 0.25)
            breakRange(f)
            XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .done, name)
            XCTAssertEqual(poster.typed, "שלום", name)
        }
    }

    @TextActor func testTypeOverWithAnUnusableRangeRefusesWhenTheSelectedTextCantBeRead() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        f.selectedRangeError = .unsupported
        f.timeouts = [.selectedText]
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testFocusedElementIsTheUnwrappedElementForTheUndoRecord() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = makeExecutor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertTrue((x.focusedElement as? FakeTextField) === f, "LastRun compares the raw element, not the latch")
        XCTAssertTrue(f.isSameElement(as: x.focusedElement!))
        x.endReplacement()
        XCTAssertNil(x.focusedElement)
    }
}
