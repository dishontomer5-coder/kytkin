// P6-0j QA (owner 2026-11-18): Spotlight, Safari's address bar and search fields select an inline completion after
// what was typed (`akuo` + selected `ab`). That selection is the app's guess: double-Shift converts the text before it
// (the selection's start is the caret) through the AX box path, and the one AX write replaces the converted range
// through the end of the completion, as typing would; the app may complete again. Never keys, never the completion's
// text. Executor and controller over FakeTextField; no real app.

import XCTest

final class InlineCompletionTests: XCTestCase {
    private let spotlight = "com.apple.Spotlight"
    private let layouts = ConvertFixtures.layouts
    private let akuoHebrew = ConvertFixtures.layouts.converter(from: IDs.abc)!.convert("akuo").text

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

    private func sel(_ location: Int, _ length: Int) -> TextRange { TextRange(location: location, length: length) }

    /// `typed` + the selected `completion`, a single-line field.
    private func field(_ typed: String, completion: String, role: String = "AXTextField") -> FakeTextField {
        let f = FakeTextField(typed + completion, selection: sel(typed.utf16.count, completion.utf16.count))
        f.role = role
        return f
    }

    // MARK: - Executor

    @TextActor private func executor(_ f: FakeTextField, poster: RecordingPoster = RecordingPoster())
        -> ReplacementExecutor {
        let x = ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: poster)
        _ = x.focusInfo(timeout: 0.25)
        return x
    }

    @TextActor func testFocusInfoNamesASelectedTailButNotAWholeOrMiddleSelection() async {
        let f = field("akuo", completion: "ab")
        let info = ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: RecordingPoster())
            .focusInfo(timeout: 0.25)
        XCTAssertEqual(info?.selectionIsFieldTail, true)
        XCTAssertEqual(info?.canReadBeforeSelection, true)

        f.selection = sel(0, 6)   // ⌘A: from the start, not a completion
        XCTAssertEqual(ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: RecordingPoster())
            .focusInfo(timeout: 0.25)?.selectionIsFieldTail, false)
        f.selection = sel(1, 2)   // in the middle
        XCTAssertEqual(ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: RecordingPoster())
            .focusInfo(timeout: 0.25)?.selectionIsFieldTail, false)
    }

    @TextActor func testWithoutBeginInlineCompletionASelectionIsNeverReadAsACaret() async {
        let x = executor(field("akuo", completion: "ab"))
        XCTAssertEqual(x.readField(maxChars: 16_384) { _ in XCTFail("no window"); return nil }, .unavailable)
    }

    @TextActor func testTheReadStopsAtTheCompletionAndTheWriteReplacesItToo() async {
        let f = field("akuo", completion: "ab")
        let poster = RecordingPoster()
        let x = executor(f, poster: poster)
        x.beginInlineCompletion()
        var seen: FieldWindow?
        XCTAssertEqual(x.readField(maxChars: 16_384) { w in
            seen = w
            return FieldEdit(offset: 0, length: 4, caretAfter: nil)
        }.verdict, .done)
        XCTAssertEqual(seen?.caret, 4, "the completion's start is the caret")
        XCTAssertEqual(seen?.upToCaret.text, "akuo", "the completion is never planned")
        XCTAssertEqual(x.wordBeforeCaret, "akuo")
        XCTAssertFalse(x.readRangeEndsAtCaret, "no key fallback")
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום").verdict, .done)
        XCTAssertEqual(f.text, "שלום")
        XCTAssertEqual(f.selection, sel(4, 0))
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testTheUnchangedTextBetweenTheRangeAndTheCompletionIsWrittenBackAsItIs() async {
        let f = field("akuo 12", completion: "xyz")
        let x = executor(f)
        x.beginInlineCompletion()
        _ = x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 0, length: 4, caretAfter: 7) }
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום").verdict, .done)
        XCTAssertEqual(f.text, "שלום 12")
    }

    @TextActor func testAnAppThatCompletesAgainAfterTheWritePassesTheReadBack() async {
        let f = field("akuo", completion: "ab")
        f.recompletes = "zz"
        let x = executor(f)
        x.beginInlineCompletion()
        _ = x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 0, length: 4, caretAfter: nil) }
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום").verdict, .done)
        XCTAssertEqual(f.text, "שלוםzz")
        XCTAssertEqual(f.selection, sel(4, 2), "the app's new completion is left alone")
    }

    @TextActor func testACompletionThatChangedBeforeTheWriteIsLeftUntouched() async {
        let f = field("akuo", completion: "ab")
        let x = executor(f)
        x.beginInlineCompletion()
        _ = x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 0, length: 4, caretAfter: nil) }
        f.units = Array("akuoabc".utf16)
        f.selection = sel(4, 3)
        let out = x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום")
        XCTAssertEqual(out, .unavailable)
        XCTAssertEqual(f.text, "akuoabc")
        XCTAssertEqual(f.selection, sel(4, 3))
    }

    @TextActor func testAWriteThatChangedNothingPutsTheCompletionBack() async {
        let f = field("akuo", completion: "ab")
        f.writeBehavior = .silentNoop
        let x = executor(f)
        x.beginInlineCompletion()
        _ = x.readField(maxChars: 16_384) { _ in FieldEdit(offset: 0, length: 4, caretAfter: nil) }
        let out = x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום")
        XCTAssertEqual(out, StepOutcome(verdict: .failedVerify, fieldUntouched: true))
        XCTAssertEqual(f.text, "akuoab")
        XCTAssertEqual(f.selection, sel(4, 2))
    }

    // MARK: - Controller

    @TextActor private func real(_ f: FakeTextField) -> (ConvertController, RecordingPoster) {
        let poster = RecordingPoster()
        let executor = ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: poster)
        let log = self.log!
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        return (sut, poster)
    }

    private func request(typed: String, bundleID: String? = nil) -> ConvertRequest {
        let strokes = ConvertFixtures.strokes(typed)
        let snap = WordSnapshot(strokes: strokes, previousWords: [], renderedIn: IDs.abc, isValid: !strokes.isEmpty)
        return ConvertRequest(snapshot: snap, gen: 1, bundleID: bundleID ?? spotlight, mode: .convert,
                              pair: ConvertFixtures.pair, currentSource: IDs.abc, switchAfterConvert: true)
    }

    /// The owner's case: Spotlight, `akuo` typed, its completion selected after it.
    @TextActor func testSpotlightsTypedTextConvertsAndTheCompletionIsReplaced() async {
        let f = field("akuo", completion: "ab")
        let (sut, poster) = real(f)
        let out = await sut.handle(request(typed: "akuo"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.text, akuoHebrew)
        XCTAssertTrue(poster.events.isEmpty, "never a key")
    }

    @TextActor func testTextBeforeTheTailThatIsNotWhatWasTypedJustSwitches() async {
        let f = field("xyz", completion: "ab")
        let (sut, poster) = real(f)
        let out = await sut.handle(request(typed: "akuo"), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .selectionPresent))
        XCTAssertEqual(f.text, "xyzab")
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testASearchFieldsCompletionConvertsTheTextBeforeItWithNothingRemembered() async {
        let f = field("akuo", completion: "ab", role: "AXSearchField")
        let (sut, poster) = real(f)
        let out = await sut.handle(request(typed: ""), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.text, akuoHebrew)
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// Nothing typed since the caret moved: a tail the user selected by hand in a text field converts as a selection.
    @TextActor func testAHandSelectedTailWithNothingTypedStillConvertsAsASelection() async {
        let f = field("hello ", completion: "akuo")
        let (sut, _) = real(f)
        let out = await sut.handle(request(typed: "", bundleID: "com.apple.TextEdit"), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.text, "hello " + akuoHebrew)
    }

    @TextActor func testACompletionAXCannotWriteJustSwitches() async {
        let f = field("akuo", completion: "ab")
        f.selTextSettable = false
        let (sut, poster) = real(f)
        let out = await sut.handle(request(typed: "akuo"), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .selectionPresent))
        XCTAssertEqual(f.text, "akuoab")
        XCTAssertTrue(poster.events.isEmpty, "no Backspace over the completion")
    }
}
