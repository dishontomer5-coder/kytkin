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
                     .axReadBeforeCaret(maxChars: 64)] {
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
                         .backspaceAndType(count: 4), .axReadBeforeCaret(maxChars: 64)] {
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

    // MARK: - Read before the caret

    @TextActor func testReadBeforeCaretFindsTheWholeWordAcrossHebrewPunctuationKeys() async {
        let x = makeExecutor(FakeTextField("hello ,usv"))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axReadBeforeCaret(maxChars: 64), old: "", new: ""),
                       StepOutcome(verdict: .done, fieldUntouched: true))
        XCTAssertEqual(x.wordBeforeCaret, ",usv")
        XCTAssertTrue(field.writes.isEmpty, "the read writes nothing")
        // The following AX write targets the word it found.
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: ",usv", new: "תודה"), .done)
        XCTAssertEqual(field.text, "hello תודה")
    }

    @TextActor func testReadBeforeCaretNeedsACaret() async {
        let x = makeExecutor(FakeTextField("hello akuo", selection: sel(6, 4)))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axReadBeforeCaret(maxChars: 64), old: "", new: ""), .unavailable)
        XCTAssertNil(x.wordBeforeCaret)
    }

    @TextActor func testReadBeforeCaretNeverGuessesACutOffWord() async {
        let long = String(repeating: "a", count: 70)
        let x = makeExecutor(FakeTextField(long))
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axReadBeforeCaret(maxChars: 64), old: "", new: ""), .unavailable)
        // At the start of the field the whole text is the word.
        let y = makeExecutor(FakeTextField("akuo"))
        _ = y.focusInfo(timeout: 0.25)
        XCTAssertEqual(y.perform(.axReadBeforeCaret(maxChars: 64), old: "", new: "").verdict, .done)
        XCTAssertEqual(y.wordBeforeCaret, "akuo")
    }
}
