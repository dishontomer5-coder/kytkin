// P3-35: the executor's whole-box read (`readField`, 001 §12.3 X11) and its write: what is read (the whole field,
// a window around the caret, retries, an unknown length), the range and caret it remembers, the caret put back after
// the write (and on an untouched failure), the tolerant read-back, the field-stop guard, and the chain's key-step
// rule for a range that reaches past the caret. Fakes only (FakeTextField, RecordingPoster).

import XCTest

final class FieldReadTests: XCTestCase {
    private var poster = RecordingPoster()
    private let app = "com.apple.TextEdit"

    @TextActor private func executor(_ f: FakeTextField) -> ReplacementExecutor {
        let x = ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: poster)
        _ = x.focusInfo(timeout: 0.25)
        return x
    }

    private func sel(_ location: Int, _ length: Int) -> TextRange { TextRange(location: location, length: length) }

    /// The real whole-box convert over the fixtures, as ConvertController locates it.
    private let locateBox: (FieldWindow) -> FieldEdit? = { w in
        let layouts = ConvertFixtures.layouts
        if case .convert(let p) = BoxConversion.plan(w, classify: layouts.runClass, convert: { side, g in
            layouts.converter(from: layouts.source(of: side))?.convert(g).text ?? g
        }) { return p.edit }
        return nil
    }

    private let pairConvert: (String) -> String? = {
        ConvertFixtures.layouts.converter(from: IDs.abc)?.convert($0).text
    }

    // MARK: - What is read

    @TextActor func testASmallFieldIsReadWholeInOneCall() async {
        let f = FakeTextField("akuo vh nv", selection: sel(4, 0))
        let x = executor(f)
        var seen: FieldWindow?
        XCTAssertEqual(x.readField(maxChars: 16_384) { seen = $0; return nil }.verdict, .done)
        XCTAssertEqual(seen, FieldWindow(text: "akuo vh nv", location: 0, caret: 4, reachesFieldStart: true,
                                         reachesFieldEnd: true))
        XCTAssertEqual(f.stringRangesRead, [sel(0, 10)])
        XCTAssertNil(x.wordBeforeCaret, "read fine, nothing there")
    }

    @TextActor func testABiggerFieldIsReadAroundTheCaretMostlyBeforeIt() async {
        let f = FakeTextField(String(repeating: "x", count: 20), selection: sel(10, 0))
        let x = executor(f)
        var seen: FieldWindow?
        _ = x.readField(maxChars: 8) { seen = $0; return nil }
        XCTAssertEqual(f.stringRangesRead, [sel(4, 8)], "¾ of the window before the caret")
        XCTAssertEqual(seen?.reachesFieldStart, false)
        XCTAssertEqual(seen?.reachesFieldEnd, false)
        XCTAssertEqual(ReplacementExecutor.window(size: 8, caret: 19, total: 20), sel(12, 8), "clamped to the end")
        XCTAssertEqual(ReplacementExecutor.window(size: 8, caret: 1, total: 20), sel(0, 8), "clamped to the start")
    }

    @TextActor func testAWrongLengthReadIsRetriedWithSmallerWindowsAroundTheCaret() async {
        let f = FakeTextField(String(repeating: "akuo ", count: 1000))   // 5,000 units, caret at the end
        f.stringForRangeExactUpTo = 1024
        let x = executor(f)
        var seen: FieldWindow?
        XCTAssertEqual(x.readField(maxChars: ReplacementPlanner.maxFieldReadChars) { seen = $0; return nil }.verdict,
                       .done)
        XCTAssertEqual(f.stringRangesRead.map(\.length), [5000, 4096, 1024])
        XCTAssertEqual(seen?.text.utf16.count, 1024)
        XCTAssertEqual(seen?.caret, 5000)
    }

    @TextActor func testEveryReadFailingIsUnavailable() async {
        let f = FakeTextField("akuo vh")
        f.stringForRangeOverride = "x"
        let x = executor(f)
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in XCTFail("no window"); return nil }, .unavailable)
    }

    @TextActor func testAnUnknownFieldLengthReadsUpToTheCaret() async {
        let f = FakeTextField("akuo vh nv", selection: sel(7, 0))
        f.numberOfCharactersError = .unsupported
        let x = executor(f)
        var seen: FieldWindow?
        _ = x.readField(maxChars: 16_384) { seen = $0; return nil }
        XCTAssertEqual(seen, FieldWindow(text: "akuo vh", location: 0, caret: 7, reachesFieldStart: true,
                                         reachesFieldEnd: false))
    }

    @TextActor func testAnEmptyFieldReadsNothing() async {
        let f = FakeTextField("")
        let x = executor(f)
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in XCTFail("no window"); return nil }.verdict, .done)
        XCTAssertTrue(f.stringRangesRead.isEmpty)
    }

    @TextActor func testACaretAtTheFieldStartCanBeRead() async {
        let f = FakeTextField("akuo", selection: sel(0, 0))
        let x = ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: poster)
        XCTAssertEqual(x.focusInfo(timeout: 0.25)?.canReadBeforeCaret, true, "P3-35: was false at location 0")
    }

    @TextActor func testASelectionIsNotACaret() async {
        let f = FakeTextField("akuo vh", selection: sel(0, 4))
        let x = executor(f)
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in nil }, .unavailable)
    }

    // MARK: - The remembered range and the guard

    @TextActor func testTheRangeAndWhetherItEndsAtTheCaret() async {
        let f = FakeTextField("akuo vh", selection: sel(4, 0))
        let x = executor(f)
        _ = x.readField(maxChars: 16_384, locate: locateBox)
        XCTAssertEqual(x.wordBeforeCaret, "akuo vh")
        XCTAssertFalse(x.readRangeEndsAtCaret)
        let g = FakeTextField("akuo vh")
        let y = executor(g)
        _ = y.readField(maxChars: 16_384, locate: locateBox)
        XCTAssertTrue(y.readRangeEndsAtCaret)
    }

    @TextActor func testARangeHoldingAnotherControlCharacterIsRefused() async {
        let f = FakeTextField("akuo\u{1B}vh")
        let x = executor(f)
        let out = x.readField(maxChars: 16_384) { w in FieldEdit(offset: 0, length: w.text.utf16.count, caretAfter: nil) }
        XCTAssertEqual(out, .unavailable)
        XCTAssertNil(x.wordBeforeCaret)
    }

    @TextActor func testARangeOutsideTheWindowOrSplittingASurrogateIsRefused() async {
        let f = FakeTextField("😀a")
        let x = executor(f)
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 1, length: 2, caretAfter: nil) },
                       .unavailable)
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 0, length: 9, caretAfter: nil) },
                       .unavailable)
    }

    // MARK: - Write and caret

    @TextActor func testTheWriteKeepsTheCaretWhereItWas() async {
        let f = FakeTextField("akuo vh nv", selection: sel(4, 0))
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: pairConvert, locateField: locateBox,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "שלום הי מה")
        XCTAssertEqual(f.selection, sel(4, 0), "the caret stays after the first word")
    }

    @TextActor func testAnUntouchedWritePutsTheCaretBackWhereTheUserHadIt() async {
        let f = FakeTextField("akuo vh nv", selection: sel(4, 0))
        f.writeBehavior = .silentNoop
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: pairConvert, locateField: locateBox,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(f.text, "akuo vh nv")
        XCTAssertEqual(f.selection, sel(4, 0), "not the end of the range")
    }

    @TextActor func testTheReadBackToleratesNoBreakSpacesInTheBox() async {
        // WebKit rebalances whitespace: the box's NBSP is written back as a plain space. Still a verified write, and
        // AX is not marked broken for the app.
        let f = FakeTextField("akuo\u{A0}vh nv")
        f.writeBehavior = .noBreakSpacesBecomeSpaces
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: pairConvert, locateField: locateBox,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "שלום הי מה")
        XCTAssertFalse(caps.isAXWriteBroken(for: app))
    }

    @TextActor func testAGarbledWriteHalts() async {
        let f = FakeTextField("akuo vh")
        f.writeBehavior = .garble
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 7)]),
                                       on: x, bundleID: app, old: "akuo vh", convert: pairConvert,
                                       locateField: locateBox, capabilities: &caps)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - Chain: the key fallback

    @TextActor func testNoKeyFallbackWhenTheRangeReachesPastTheCaret() async {
        // The range "akuo vh" equals the buffer's text, but it doesn't end at the caret: Backspace × 7 from the caret
        // would delete the wrong text. The key step is skipped.
        let f = FakeTextField("akuo vh", selection: sel(4, 0))
        f.writeBehavior = .silentNoop
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 7)]),
                                       on: x, bundleID: app, old: "akuo vh", convert: pairConvert,
                                       locateField: locateBox, capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(f.text, "akuo vh")
    }

    @TextActor func testTheKeyFallbackStillRunsWhenTheRangeEndsAtTheCaretAndIsTheBuffer() async {
        let f = FakeTextField("akuo vh")
        f.writeBehavior = .silentNoop
        let x = executor(f)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 7)]),
                                       on: x, bundleID: app, old: "akuo vh", convert: pairConvert,
                                       locateField: locateBox, capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .backspaceAndType(count: 7)))
        XCTAssertEqual(poster.backspaceCount, 7)
    }

    @TextActor func testTheReadIsReadOnlyAndNeverAsksForTheClaim() async {
        let f = FakeTextField("123")
        let x = executor(f)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadField(maxChars: 16_384), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: pairConvert, locateField: locateBox,
                                       capabilities: &caps, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(f.writes.isEmpty)
    }
}
