// P3-35: ConvertController's whole-box convert (owner 2026-11-11, plan.md P3-35, 001 §12.3 X11), end to end over the
// real executor on a FakeTextField: a mixed box (Hebrew correct + English wrong, before and after the caret), the empty
// new line after Return, the caret kept, punctuation next to Hebrew kept, a box over the 16,384-unit cap, the tolerant
// read-back, no key fallback for a range past the caret, and the selection path unchanged. P3-40 (owner 2026-11-11):
// a second double-Shift converts the whole box again to the other language (`1 2 1` → `2 2 2` → `1 1 1`), no undo;
// these replace the P3-35 exact-undo tests. Fakes only.

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

    private func empty(in source: InputSourceID = IDs.abc) -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: source, isValid: false)
    }

    private func buffer(_ current: String) -> WordSnapshot {
        let strokes = ConvertFixtures.strokes(current)
        return WordSnapshot(strokes: strokes, previousWords: [], renderedIn: IDs.abc, isValid: true)
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
    }

    // MARK: - P3-40 (b): a selection whose AXSelectedText lost its line breaks is never written without them

    /// TextEdit/Mail path (AX write): AXSelectedText drops the break, and the app's range agrees with that length.
    /// Before P3-40 the AX write replaced the real (longer) selection with converted text that had no line break.
    @TextActor func testAnAXWriteIsRefusedWhenTheSelectedTextLostItsLineBreak() async {
        let field = FakeTextField("x akuo\nvh y", selection: TextRange(location: 2, length: 7))
        field.selectedTextDropsLineBreaks = true
        field.reportedRange = TextRange(location: 2, length: 6)   // what a Chromium-like app reports for "akuovh"
        let (sut, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertTrue(field.text == "x akuo\nvh y", "the line break is never lost")
        XCTAssertTrue(poster.events.isEmpty, "not typed over either")
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(out.shouldBeepForTest)
    }

    /// The one-line type-over path (a keys-only app with the clipboard off): the same selection is not typed over.
    @TextActor func testATypeOverIsRefusedWhenTheSelectedTextLostItsLineBreak() async {
        for reported in [TextRange(location: 2, length: 6), nil] as [TextRange?] {
            let field = FakeTextField("x akuo\nvh y", selection: TextRange(location: 2, length: 7))
            field.selectedTextDropsLineBreaks = true
            field.reportedRange = reported
            let (sut, poster) = real(field)
            let r = ConvertRequest(snapshot: empty(), gen: 1, bundleID: "com.tinyspeck.slackmacgap", mode: .convert,
                                   pair: ConvertFixtures.pair, currentSource: IDs.abc, switchAfterConvert: true)
            await sut.handle(r, layouts: layouts)
            XCTAssertTrue(field.text == "x akuo\nvh y", "\(String(describing: reported))")
            XCTAssertTrue(poster.events.isEmpty, "never typed without the line break: \(String(describing: reported))")
        }
    }

    @TextActor func testAMultiLineSelectionWithItsLineBreakStillConvertsThroughAX() async {
        let field = FakeTextField("x akuo\nvh y", selection: TextRange(location: 2, length: 7))
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "x שלום\nהי y")
    }

    // MARK: - P3-40: a second double-Shift converts again (no undo)

    @TextActor func testASecondDoubleShiftConvertsTheWholeBoxToTheOtherLanguage() async {
        // The owner's Slack/TextEdit test, word N = a word in language N: `1 2 1` → `2 2 2` → `1 1 1` → `2 2 2`.
        let field = FakeTextField("akuo שלום vh")
        let (sut, poster) = real(field)
        let first = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(first, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הי")

        let second = await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(second, .converted(to: IDs.abc, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "akuo akuo vh", "not the original `1 2 1`: the whole box in the other language")

        await sut.handle(request(empty(), gen: 3), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום הי")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true), .switchTo(IDs.abc, keepsBuffer: true),
                                      .switchTo(IDs.hebrew, keepsBuffer: true)])
    }

    @TextActor func testTheSecondConvertIsAFreshConvertCapitalsAndAll() async {
        // A per-character convert doesn't round-trip capitals (`A` → `ש` → `a`); the original is not kept any more
        // (P3-40), so ⌘Z in the app is the way back to it. The caret stays where the user had it each time.
        let field = FakeTextField("Akuo שלום, VH.\nnhv", selection: TextRange(location: 4, length: 0))
        let (sut, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום, היץ\nמיה")
        await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        // The comma after a Hebrew word converts with it (BoxConversion rule e: on Apple Hebrew `,` is the `'` key).
        XCTAssertEqual(field.text, "akuo akuo' vh.\nnhv")
        XCTAssertEqual(field.selection, TextRange(location: 4, length: 0))
    }

    @TextActor func testTheReadBackToleranceKeepsAXWorkingInAWebKitField() async {
        let field = FakeTextField("akuo\u{A0}vh")
        field.writeBehavior = .noBreakSpacesBecomeSpaces
        let (sut, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axWrite, switched: true))
        XCTAssertEqual(field.text, "שלום הי")
        XCTAssertFalse(sut.capabilities.isAXWriteBroken(for: app))
        // P3-40: the second double-Shift converts the box again (the field's own space stays a space).
        await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(field.text, "akuo vh")
    }
}

private extension ConvertOutcome {
    var shouldBeepForTest: Bool {
        if case .noop = self { return true }
        return false
    }
}
