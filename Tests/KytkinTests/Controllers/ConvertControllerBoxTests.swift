// P3-35: ConvertController's whole-box convert (owner 2026-11-11, plan.md P3-35, 001 §12.3 X11), end to end over the
// real executor on a FakeTextField: a mixed box (Hebrew correct + English wrong, before and after the caret), the empty
// new line after Return, the caret kept, punctuation next to Hebrew kept, a box over the 16,384-unit cap, an exact
// undo (capitals and mixed text, which a per-character round trip would lose), the tolerant read-back, no key
// fallback for a range past the caret, and the selection path unchanged. Fakes only.

import XCTest

final class ConvertControllerBoxTests: XCTestCase {
    private let app = "com.apple.TextEdit"
    private let layouts = ConvertFixtures.layouts

    private var log: ConvertLog!
    private var watcher: ConvertKeyWatcher!
    private var switches: SwitchRecorder!
    private var clock: FakeClock!

    override func setUp() {
        log = ConvertLog()
        watcher = ConvertKeyWatcher(log: log)
        switches = SwitchRecorder(log: log)
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    @TextActor private func real(_ field: FakeTextField) -> (ConvertController, RecordingPoster) {
        let poster = RecordingPoster()
        let executor = ReplacementExecutor(focusProvider: FakeFocusProvider(field), poster: poster)
        let log = self.log!
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        return (sut, poster)
    }

    private func empty(untouched: UInt64? = nil, in source: InputSourceID = IDs.abc) -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: source, isValid: false,
                     untouchedSinceConvert: untouched)
    }

    private func buffer(_ current: String, untouched: UInt64? = nil) -> WordSnapshot {
        let strokes = ConvertFixtures.strokes(current)
        return WordSnapshot(strokes: strokes, previousWords: [], renderedIn: IDs.abc, isValid: true,
                            untouchedSinceConvert: untouched)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64, current: InputSourceID = IDs.abc) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: app, mode: .convert, pair: ConvertFixtures.pair,
                       currentSource: current, switchAfterConvert: true)
    }

    private var axWrite: ReplacementStep { .axWriteSelection(verify: true) }

    // MARK: - The whole box

    @TextActor func testAMixedBoxConvertsTheWrongLanguageBeforeAndAfterTheCaretInOneWrite() async {
        let before = "שלום, מה akuo vh."
        let field = FakeTextField(before + "\nnv תודה.\nhello", selection: TextRange(location: before.utf16.count,
                                                                                         length: 0))
        let (sut, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום, מה שלום היץ\nמה תודה.\nיקךךם")
        XCTAssertEqual(field.selection, TextRange(location: before.utf16.count, length: 0), "the caret stays put")
        XCTAssertEqual(field.writes.filter { $0 == .selectedText }.count, 1, "one AX write")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
    }

    @TextActor func testAnEmptyNewLineAfterReturnConvertsTheBox() async {
        let field = FakeTextField("akuo vh\nnv\n")
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום הי\nמה\n")
        XCTAssertEqual(field.selection, TextRange(location: 11, length: 0), "still on the empty line")
    }

    @TextActor func testTheCaretInTheMiddleOfTheBoxStaysThere() async {
        let field = FakeTextField("akuo vh nv", selection: TextRange(location: 4, length: 0))
        let (sut, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום הי מה")
        XCTAssertEqual(field.selection, TextRange(location: 4, length: 0))
    }

    @TextActor func testPunctuationNextToHebrewIsKept() async {
        let field = FakeTextField("מס' 5, \"שלום\". tkhk")
        let (sut, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "מס' 5, \"שלום\". אליל")
    }

    @TextActor func testTheCaretAtTheFieldStartUsesTheLetterAfterIt() async {
        let field = FakeTextField("akuo", selection: TextRange(location: 0, length: 0))
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום")
        XCTAssertEqual(field.selection, TextRange(location: 0, length: 0))
    }

    @TextActor func testABoxOverTheCapConvertsTheWindowAroundTheCaretOnWordBoundaries() async {
        // 20,000+ units: Latin far before the window stays; the window's first (cut) word stays; the rest converts.
        let far = "akuo "
        let filler = String(repeating: "שלום ", count: 4000)          // 20,000 units
        let field = FakeTextField(far + filler + "akuo vh")
        let total = field.units.count
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertTrue(field.text.hasPrefix(far), "outside the window: untouched")
        XCTAssertTrue(field.text.hasSuffix("שלום שלום הי"))
        XCTAssertEqual(field.units.count, total)
        XCTAssertEqual(field.stringRangesRead.first, TextRange(location: total - ReplacementPlanner.maxFieldReadChars,
                                                               length: ReplacementPlanner.maxFieldReadChars))
    }

    @TextActor func testABufferEqualToTheRangeAtTheCaretIsStillKeptReRendered() async {
        let field = FakeTextField("שלום akuo")
        let (sut, _) = real(field)
        await sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
    }

    @TextActor func testNoKeyFallbackForARangeThatReachesPastTheCaret() async {
        // The AX write does nothing; the buffer is "akuo" but the box's range is "akuo vh" around the caret.
        let field = FakeTextField("akuo vh", selection: TextRange(location: 4, length: 0))
        field.writeBehavior = .silentNoop
        let (sut, poster) = real(field)
        let out = await sut.handle(request(buffer("akuo"), gen: 1), layouts: layouts)
        XCTAssertTrue(poster.events.isEmpty, "never Backspace from the caret over text after it")
        XCTAssertEqual(field.text, "akuo vh")
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(out.shouldBeepForTest)
    }

    @TextActor func testASelectionStillConvertsOnlyTheSelection() async {
        let field = FakeTextField("akuo vh nv", selection: TextRange(location: 5, length: 2))
        let (sut, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "akuo הי nv")
        XCTAssertNil(sut.lastRun)
    }

    // MARK: - Undo

    @TextActor func testUndoRestoresExactlyWhatAPerCharacterRoundTripWouldLose() async {
        // Capitals (Shift letters convert to plain Hebrew) and correct Hebrew between the converted words.
        let original = "Akuo שלום, VH.\nnhv"
        let field = FakeTextField(original, selection: TextRange(location: 4, length: 0))
        let (sut, poster) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום, היץ\nמיה")
        XCTAssertEqual(field.selection, TextRange(location: 4, length: 0))

        let back = await sut.handle(request(empty(untouched: 1, in: IDs.hebrew), gen: 2, current: IDs.hebrew),
                                    layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axWrite, switched: true))
        XCTAssertTrue(field.text == original, "undone exactly, capitals and all")
        XCTAssertEqual(field.selection, TextRange(location: 4, length: 0), "the caret where it was")
        XCTAssertNil(sut.lastRun, "the replaced text is dropped with the record")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(log.switches.last, .switchTo(IDs.abc, keepsBuffer: true))
    }

    @TextActor func testWithoutTheRecordASecondDoubleShiftConvertsTheBoxAgain() async {
        // Once the record is gone (P3-35 QA, owner: a key, click or focus change drops it; no timer) the next
        // double-Shift is a plain whole-box convert from the letter at the caret (now Hebrew), which is why the undo
        // record matters. ⌘Z stays available in the app.
        let field = FakeTextField("akuo")
        let (sut, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        sut.forgetUndoRecord()
        await sut.handle(request(empty(untouched: 1, in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(field.text, "akuo")
    }

    @TextActor func testTheReadBackToleranceKeepsAXWorkingInAWebKitField() async {
        let field = FakeTextField("akuo\u{A0}vh")
        field.writeBehavior = .noBreakSpacesBecomeSpaces
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום הי")
        XCTAssertFalse(sut.capabilities.isAXWriteBroken(for: app))
        // The undo recognises the written text despite the space swap (the fingerprint maps NBSP to a space).
        await sut.handle(request(empty(untouched: 1, in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(field.text, "akuo vh", "the original, with the field's own space")
    }
}

private extension ConvertOutcome {
    var shouldBeepForTest: Bool {
        if case .noop = self { return true }
        return false
    }
}
