// P2-59c: ConvertController's run flow (001 §12.3 X4–X7, X8 "Controller"), with fakes only: the AX run through the
// real executor on a FakeTextField, the key path on a scripted replacer, the X5 buffer-after table, the switch target,
// `.runTooLong`, the P2-54(a) silent switch, the X6 `LastRun` undo record (forward, back, forward) and every reason it
// is refused (focus change, caret move, age, content change, other app/process, keys since), the finish-exactly-once
// invariant across the new paths, and that the record holds no text.
// P3-35: a readable field now converts the whole text box (`axReadField`, `BoxConversion`); the tests below that
// asserted the P2-59/P3-33 run-before-caret behaviour are changed to the whole-box behaviour (marked P3-35), and the
// undo record now restores the replaced text exactly (it holds that text for the undo window only).

import XCTest

final class ConvertControllerRunTests: XCTestCase {
    private let app = "com.apple.TextEdit"
    private let terminal = "com.apple.Terminal"
    private let slack = "com.tinyspeck.slackmacgap"
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

    // MARK: - Helpers

    /// A controller over the real executor and a fake AX field (the read calls `locate`, the write is verified).
    @TextActor private func real(_ field: FakeTextField) -> (ConvertController, FakeFocusProvider, RecordingPoster) {
        let provider = FakeFocusProvider(field)
        let poster = RecordingPoster()
        let executor = ReplacementExecutor(focusProvider: provider, poster: poster)
        let log = self.log!
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        return (sut, provider, poster)
    }

    @TextActor private func scripted(readable: Bool = false) -> (ConvertController, ScriptedReplacer) {
        let r = ScriptedReplacer(log: log)
        r.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
                            selRangeSettable: true, selection: nil, canReadBeforeCaret: readable)
        let log = self.log!
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { r }, switchLanguage: switches.hook)
        return (sut, r)
    }

    /// The buffer: earlier words (ABC keys), the spaces after each, and the current word.
    private func buffer(_ words: [String], gaps: [Int]? = nil, current: String, in source: InputSourceID?,
                        untouched: UInt64? = nil) -> WordSnapshot {
        let strokes = ConvertFixtures.strokes(current)
        return WordSnapshot(strokes: strokes, previousWords: words.map(ConvertFixtures.strokes), renderedIn: source,
                            isValid: !strokes.isEmpty, gaps: gaps, untouchedSinceConvert: untouched)
    }

    private func empty(untouched: UInt64? = nil, in source: InputSourceID = IDs.abc) -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: source, isValid: false,
                     untouchedSinceConvert: untouched)
    }

    private func request(_ snapshot: WordSnapshot, gen: UInt64, bundleID: String? = nil,
                         current: InputSourceID = IDs.abc, switchAfter: Bool = true) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot, gen: gen, bundleID: bundleID ?? app, mode: .convert,
                       pair: ConvertFixtures.pair, currentSource: current, switchAfterConvert: switchAfter)
    }

    private var axRun: ReplacementStep { .axWriteSelection(verify: true) }

    // MARK: - AX run (readable field)

    @TextActor func testOwnersExampleConvertsOnlyTheWrongPartAndForgetsADifferentBuffer() async {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(buffer([], current: "nhv", in: IDs.abc), gen: 1), layouts: layouts)

        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הית מיה")
        XCTAssertTrue(poster.events.isEmpty)
        // X5: the AX run ≠ the buffer → forget it; the switch still keeps the processor from resetting (X6 undo).
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
        // X6: a range-only record of what was written.
        let rec = sut.lastRun
        XCTAssertEqual(rec?.gen, 1)
        XCTAssertEqual(rec?.location, 5)
        XCTAssertEqual(rec?.length, "שלום הית מיה".utf16.count)
        XCTAssertEqual(rec?.from, .b)
        XCTAssertEqual(rec?.to, .a)
        XCTAssertEqual(rec?.bundleID, app)
        XCTAssertEqual(rec?.processID, 4242)
    }

    @TextActor func testAnAXRunEqualToTheBufferKeepsTheWholeBufferReRendered() async {
        let field = FakeTextField("שלום akuo vh")
        let (sut, _, _) = real(field)
        let out = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הי")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
        XCTAssertNotNil(sut.lastRun)
    }

    @TextActor func testAnAXRunEqualToTheBufferWithSwitchOffUsesBufferRenderedInAndConvertsBack() async {
        let field = FakeTextField("שלום akuo vh")
        let (sut, _, _) = real(field)
        await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1, switchAfter: false),
                         layouts: layouts)
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil, renderedIn: IDs.hebrew)])
        XCTAssertEqual(field.text, "שלום שלום הי")

        // The processor now snapshots the kept buffer in Hebrew while the source stays ABC.
        log.clear()
        let back = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.hebrew, untouched: 1), gen: 2,
                                            switchAfter: false), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axRun, switched: false))
        XCTAssertEqual(field.text, "שלום akuo vh")
        XCTAssertEqual(log.finishes, [.finish(gen: 2, newRendering: nil, bufferAfter: nil, renderedIn: IDs.abc)])
    }

    /// X4: the AX write changed nothing (and the caret is back) and the AX run is exactly the buffer → the keys.
    @TextActor func testAnUntouchedAXWriteFallsBackToKeysWhenTheRunIsTheBuffer() async {
        let field = FakeTextField("שלום akuo vh")
        field.writeBehavior = .silentNoop
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 7), switched: true))
        XCTAssertEqual(poster.backspaceCount, 7)
        XCTAssertEqual(poster.typed, "שלום הי")
        XCTAssertEqual(log.claims, [1], "one claim, before the AX write, none again for the keys")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
        XCTAssertNil(sut.lastRun, "a key convert keeps its buffer instead of a record")
    }

    @TextActor func testTheSwitchTargetsTheRunsSideNotTheOtherThanTheCurrentSource() async {
        // The source is already Hebrew, but the run is Latin: the switch still goes to Hebrew.
        let field = FakeTextField("akuo")
        let (sut, _, _) = real(field)
        let out = await sut.handle(request(empty(in: IDs.hebrew), gen: 1, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
    }

    @TextActor func testARunLongerThanTheWindowBeepsAndWritesNothing() async {
        // P3-33: scaled to the 4,096-unit window (was 300 against 256). P3-35: a box of one word bigger than the
        // 16,384-unit field cap (a 4,140-unit word now fits the box and converts).
        let long = String(repeating: "a", count: ReplacementPlanner.maxFieldReadChars + 44)
        let field = FakeTextField(long)
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.runTooLong))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(field.text == long, "nothing written")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    @TextActor func testNothingToConvertBeforeTheCaretSwitchesSilently() async {
        let field = FakeTextField("123")
        let (sut, _, _) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertEqual(field.text, "123")
    }

    /// QA (P2-59c): a readable field whose run read then fails, with words in the buffer that can't be counted (a
    /// dead key: no key step is planned). That is "couldn't convert", a beep, not a silent switch.
    @TextActor func testAFailedReadWithAnUncountableBufferBeeps() async {
        let (sut, r) = scripted(readable: true)
        r.results[.read] = .unavailable
        let dead = WordSnapshot(strokes: [Stroke(keyCode: 14, layer: .option)] + ConvertFixtures.strokes("akuo"),
                                previousWords: [], renderedIn: IDs.abc, isValid: true)
        let out = await sut.handle(request(dead, gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.exhausted)))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    /// The same failed read with nothing remembered: just switch (P2-54(a)).
    @TextActor func testAFailedReadWithAnEmptyBufferSwitchesSilently() async {
        let (sut, r) = scripted(readable: true)
        r.results[.read] = .unavailable
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.claims.isEmpty)
    }

    /// P3-33: was "the run stops at a line break"; now the whole wrong run converts, across lines, in one AX write.
    @TextActor func testTheRunCrossesALineBreak() async {
        let field = FakeTextField("akuo\nvh")
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום\nהי")
        XCTAssertTrue(poster.events.isEmpty, "never typed: the line break is put back by the AX write")
    }

    /// P3-33: a multi-line wrong run stopped at the line above that is already in the other language.
    /// P3-35 (owner): the whole box converts: the English line above becomes Hebrew too; the Hebrew line stays.
    @TextActor func testAMultiLineBoxConvertsEveryLineOfTheCaretSideLanguage() async {
        let field = FakeTextField("hello world\nשלום\nakuo vh\nnhv")
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "יקךךם ׳םרךג\nשלום\nשלום הי\nמיה")
    }

    /// P3-33: a long multi-line run (≈ 3,000 units over 50 lines) converts whole, and double-Shift again undoes it.
    @TextActor func testALongMultiLineRunConvertsWholeAndUndoes() async {
        let line = String(repeating: "akuo ", count: 12) + "\n"          // 61 units
        let original = "שלום\n" + String(repeating: line, count: 50) + "vh"
        let field = FakeTextField(original)
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        let converted = "שלום\n" + String(repeating: String(repeating: "שלום ", count: 12) + "\n", count: 50) + "הי"
        XCTAssertTrue(field.text == converted, "the whole run, every line")
        XCTAssertEqual(sut.lastRun?.length, original.utf16.count - 5)
        // Undo: double-Shift again, nothing touched since.
        let back = await sut.handle(request(empty(untouched: 1, in: IDs.hebrew), gen: 2, current: IDs.hebrew),
                                    layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axRun, switched: true))
        XCTAssertTrue(field.text == original, "undone exactly")
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - Key path (unreadable apps)

    @TextActor func testKeysOnlyAppConvertsTheWholeBufferInOneCountAndKeepsIt() async {
        let (sut, r) = scripted(readable: true)
        let snap = buffer(["akuo", "vh"], current: "nhv", in: IDs.abc)
        let out = await sut.handle(request(snap, gen: 1, bundleID: slack), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 11), switched: true))
        XCTAssertEqual(log.performs, [.backspaceAndType(count: 11)], "no AX read in a keysOnly app")
        XCTAssertEqual(r.writes.map(\.old), ["akuo vh nhv"])
        XCTAssertEqual(r.writes.map(\.new), ["שלום הי מיה"])
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
        XCTAssertNil(sut.lastRun)
    }

    /// P3-33: a long buffer (100 words, 502 keys: what the owner types in Slack before Return) converts whole by keys,
    /// in one Backspace count, and the kept buffer converts straight back (undo).
    @TextActor func testKeysOnlyAppConvertsALongBufferWholeAndUndoes() async {
        let (sut, r) = scripted(readable: true)
        let words = Array(repeating: "akuo", count: 100)
        let snap = buffer(words, current: "vh", in: IDs.abc)
        let out = await sut.handle(request(snap, gen: 1, bundleID: slack), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 502), switched: true))
        XCTAssertTrue(r.writes.map(\.new) == [String(repeating: "שלום ", count: 100) + "הי"], "the whole buffer")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
        let back = await sut.handle(request(buffer(words, current: "vh", in: IDs.hebrew, untouched: 1), gen: 2,
                                            bundleID: slack, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .backspaceAndType(count: 502), switched: true))
        XCTAssertTrue(r.writes.last?.new == String(repeating: "akuo ", count: 100) + "vh", "undone exactly")
    }

    /// P3-33: the real executor posts a full-size key run: ≤ 512 Backspaces, then the text in ≤ 16-unit chunks.
    @TextActor func testAFullSizeKeyRunIsPostedByTheExecutor() async {
        let field = FakeTextField("")
        let (sut, _, poster) = real(field)
        let words = Array(repeating: "akuo", count: 102)          // 102 × 5 = 510, + "vh" = 512 keys
        let out = await sut.handle(request(buffer(words, current: "vh", in: IDs.abc), gen: 1, bundleID: slack),
                                   layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 512), switched: true))
        let backspaces = poster.events.filter { $0.unicode.isEmpty }.count
        XCTAssertEqual(backspaces, 2 * 512)
        XCTAssertEqual(poster.events.count - backspaces, 2 * 32, "512 units in 16-unit chunks, down + up")
    }

    @TextActor func testTerminalPingPongNeverReadsThroughAX() async {
        let (sut, r) = scripted(readable: true)
        await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1, bundleID: terminal),
                         layouts: layouts)
        // The kept buffer, now in Hebrew (newRendering), converts straight back.
        let back = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.hebrew, untouched: 1), gen: 2,
                                            bundleID: terminal, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .backspaceAndType(count: 7), switched: true))
        XCTAssertEqual(r.writes.map(\.new), ["שלום הי", "akuo vh"])
        XCTAssertFalse(log.performs.contains(.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars)))
        XCTAssertEqual(log.finishes.last, .finish(gen: 2, newRendering: IDs.abc, bufferAfter: nil))
    }

    @TextActor func testTerminalWithSwitchOffKeepsTheBufferRenderedInTheTarget() async {
        let (sut, r) = scripted()
        await sut.handle(request(buffer([], current: "akuo", in: IDs.abc), gen: 1, bundleID: terminal,
                                 switchAfter: false), layouts: layouts)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil, renderedIn: IDs.hebrew)])
        // The snapshot now says Hebrew (bufferRendering) while the source is still ABC: the target is ABC.
        let back = await sut.handle(request(buffer([], current: "akuo", in: IDs.hebrew, untouched: 1), gen: 2,
                                            bundleID: terminal, switchAfter: false), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .backspaceAndType(count: 4), switched: false))
        XCTAssertEqual(r.writes.map(\.new), ["שלום", "akuo"])
        XCTAssertTrue(log.switches.isEmpty)
    }

    @TextActor func testTheKeyPathTargetComesFromTheSnapshotsRendering() async {
        // A kept buffer rendered in ABC while the source is Hebrew (switch off earlier): it converts to Hebrew.
        let (sut, _) = scripted()
        let out = await sut.handle(request(buffer([], current: "akuo", in: IDs.abc), gen: 1, bundleID: terminal,
                                           current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
    }

    @TextActor func testTrailingSpacesCountInTheKeyRun() async {
        let (sut, r) = scripted()
        await sut.handle(request(buffer(["akuo"], gaps: [2], current: "", in: IDs.abc), gen: 1, bundleID: terminal),
                         layouts: layouts)
        XCTAssertEqual(log.performs, [.backspaceAndType(count: 6)])
        XCTAssertEqual(r.writes.map(\.new), ["שלום  "])
    }

    @TextActor func testAnUncountableBufferInAnUnreadableAppBeepsInsteadOfGuessing() async {
        // A dead key: `typedRun` is nil, so `typedLength` is nil and no Backspace count is ever made up.
        let (sut, _) = scripted()
        let dead = WordSnapshot(strokes: [Stroke(keyCode: 14, layer: .option)] + ConvertFixtures.strokes("akuo"),
                                previousWords: [], renderedIn: IDs.abc, isValid: true)
        let out = await sut.handle(request(dead, gen: 1, bundleID: terminal), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.noMethod))))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.performs.isEmpty)
    }

    // MARK: - P2-54(a): unreadable and nothing remembered → just switch

    @TextActor func testUnknownFocusWithAnEmptyBufferJustSwitchesSilently() async {
        let (sut, r) = scripted()
        r.focus = nil
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }

    @TextActor func testUnknownFocusWithABufferStillBeeps() async {
        let (sut, r) = scripted()
        r.focus = nil
        let out = await sut.handle(request(buffer([], current: "akuo", in: IDs.abc), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.focusUnknown))))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.switches.isEmpty)
    }

    @TextActor func testAPasswordFieldIsStillRefusedWithAnEmptyBuffer() async {
        let (sut, r) = scripted()
        r.focus = FocusInfo(role: FocusInfo.secureTextFieldRole, isSecure: true, hasMarkedText: false,
                            selTextSettable: false, selRangeSettable: false, selection: nil)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.secureField))))
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertEqual(log.beeps, 1)
    }

    // MARK: - X6 undo record

    @TextActor func testUndoByTheRecordForwardBackForward() async {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום הית מיה")

        // Without the record the scan would take the whole (now all-Hebrew) line.
        let back = await sut.handle(request(empty(untouched: 1, in: IDs.hebrew), gen: 2, current: IDs.hebrew),
                                    layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום akuo vh, nhv")
        // P3-35: an undo keeps no record (it held the replaced text); the third double-Shift is a plain convert of
        // the restored box, the same as the first.
        XCTAssertNil(sut.lastRun)
        XCTAssertEqual(log.switches.last, .switchTo(IDs.abc, keepsBuffer: true))

        let again = await sut.handle(request(empty(untouched: 2), gen: 3), layouts: layouts)
        XCTAssertEqual(again, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הית מיה")
        XCTAssertEqual(sut.lastRun?.gen, 3)
    }

    /// Converts the owner's example once (gen 1), so a record exists; returns the field.
    @TextActor private func convertedOnce() async -> (ConvertController, FakeTextField, FakeFocusProvider) {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, provider, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום הית מיה")
        XCTAssertNotNil(sut.lastRun)
        return (sut, field, provider)
    }

    /// The normal scan's answer on the converted line: the whole line, not the recorded range.
    private let wholeLineBack = "akuo akuo vh, nhv"

    @TextActor func testUndoRefusedWhenNothingSaysTheFieldIsUntouched() async {
        let (sut, field, _) = await convertedOnce()
        await sut.handle(request(empty(untouched: nil), gen: 2), layouts: layouts)   // a key or click since
        XCTAssertEqual(field.text, wholeLineBack)
    }

    @TextActor func testUndoRefusedForAnOlderGeneration() async {
        let (sut, field, _) = await convertedOnce()
        await sut.handle(request(empty(untouched: 0), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, wholeLineBack)
    }

    @TextActor func testUndoRefusedAfterAFocusChange() async {
        let (sut, field, provider) = await convertedOnce()
        let other = FakeTextField(field.text)   // another element with the same text
        provider.result = .success(other)
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(other.text, wholeLineBack)
    }

    @TextActor func testUndoRefusedInAnotherProcess() async {
        let (sut, field, _) = await convertedOnce()
        field.processID = 9999   // relaunched app
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, wholeLineBack)
    }

    @TextActor func testUndoRefusedInAnotherApp() async {
        let (sut, field, _) = await convertedOnce()
        await sut.handle(request(empty(untouched: 1), gen: 2, bundleID: "com.apple.Notes"), layouts: layouts)
        XCTAssertEqual(field.text, wholeLineBack)
    }

    /// P3-35: was "undo refused after a caret move". The undo now checks the text it wrote (fingerprint), not the
    /// caret, so a caret move the tap didn't see (an arrow key or a click resets `untouchedSinceConvert` anyway)
    /// still undoes exactly and puts the caret back where it was before the convert.
    @TextActor func testUndoAfterACaretMoveTheTapMissedStillRestoresExactly() async {
        let (sut, field, _) = await convertedOnce()
        field.selection = TextRange(location: 4, length: 0)   // after the first word
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, "שלום akuo vh, nhv")
        XCTAssertEqual(field.selection, TextRange(location: 17, length: 0), "the caret from before the convert")
    }

    /// P3-35 QA (owner): no age limit any more (was 5 s): an hour later, untouched, the undo still restores exactly.
    @TextActor func testUndoHasNoAgeLimit() async {
        let (sut, field, _) = await convertedOnce()
        clock.advance(byNanos: 3_600_000_000_000)
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, "שלום akuo vh, nhv")
    }

    /// P3-35 QA (owner): `forgetUndoRecord` (a key, click, focus change, Pause, Secure Input) drops the record and
    /// its text; the next double-Shift is a normal convert even if the snapshot still says untouched.
    @TextActor func testForgetUndoRecordDropsTheRecordAndTheUndo() async {
        let (sut, field, _) = await convertedOnce()
        XCTAssertNotNil(sut.lastRun)
        sut.forgetUndoRecord()
        XCTAssertNil(sut.lastRun)
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, wholeLineBack)
    }

    @TextActor func testUndoRefusedWhenTheTailNowHoldsTheOtherSide() async {
        // Dictation (no key event) replaced the last letter with a Latin one; same length, caret at the end.
        let (sut, field, _) = await convertedOnce()
        field.units[field.units.count - 1] = UInt16(UnicodeScalar("x").value)
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום הית מיס", "the normal scan converts only the new Latin letter")
    }

    /// P3-33: was a line break; a line break no longer stops the run, so the hard stop here is a tab.
    /// P3-35: the written text changed (a tab instead of a space), so the record is refused; the normal convert then
    /// takes the whole box (a tab is crossed now), from the Hebrew letter before the caret.
    @TextActor func testUndoRefusedWhenTheWrittenTextChanged() async {
        let (sut, field, _) = await convertedOnce()
        let i = field.units.count - 4   // the space before "מיה"
        field.units[i] = 9
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, "akuo akuo vh,\tnhv")
    }

    @TextActor func testUndoRefusedWhenTheTailHasNoLetterOfItsSide() async {
        let (sut, field, _) = await convertedOnce()
        let n = sut.lastRun!.length
        let start = field.units.count - n
        for i in start..<field.units.count { field.units[i] = UInt16(UnicodeScalar("1").value) }
        let out = await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        // The scan crosses the digits to the Hebrew word before them and converts that run instead.
        XCTAssertEqual(out, .converted(to: IDs.abc, by: axRun, switched: true))
        XCTAssertEqual(field.text, "akuo " + String(repeating: "1", count: n))
    }

    @TextActor func testUndoRefusedWhenTheFieldGrewBeforeTheRun() async {
        // An Edit-menu paste (a click, but say it were missed) inserted text before the run: the caret moved.
        let (sut, field, _) = await convertedOnce()
        field.units.insert(contentsOf: Array("zz ".utf16), at: 0)
        field.selection = TextRange(location: field.units.count, length: 0)
        await sut.handle(request(empty(untouched: 1), gen: 2), layouts: layouts)
        XCTAssertEqual(field.text, "zz akuo akuo vh, nhv")
    }

    @TextActor func testAnyOtherRequestDropsTheRecord() async {
        let (sut, _, _) = await convertedOnce()
        await sut.handle(ConvertRequest(snapshot: empty(untouched: 1), gen: 2, bundleID: app, mode: .toggleOnly,
                                        pair: ConvertFixtures.pair, currentSource: IDs.hebrew), layouts: layouts)
        XCTAssertNil(sut.lastRun)
    }

    @TextActor func testASelectionConvertKeepsNoRecord() async {
        let field = FakeTextField("hello akuo world", selection: TextRange(location: 6, length: 4))
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "hello שלום world")
        XCTAssertNil(sut.lastRun)
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
    }

    @TextActor func testAnElementWithNoProcessIDGetsNoRecord() async {
        let field = FakeTextField("akuo")
        field.processID = nil
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום")
        XCTAssertNil(sut.lastRun)
    }

    // MARK: - Privacy

    /// P3-35: was "the record holds no text". An exact undo needs the replaced text (a per-character convert doesn't
    /// round-trip), so `original` is the one text field; the written text is only a SHA-256 fingerprint. The text
    /// lives for the undo window only: the next request takes it out, and the expiry drops it after the age limit.
    @TextActor func testTheRecordHoldsOnlyTheReplacedTextAndOnlyForTheUndoWindow() async {
        let (sut, _, _) = await convertedOnce()
        let rec = try! XCTUnwrap(sut.lastRun)
        var labels: [String] = []
        for child in Mirror(reflecting: rec).children {
            let label = child.label ?? "?"
            labels.append(label)
            if label == "bundleID" || label == "original" { continue }   // an id; the one text field, below
            XCTAssertFalse(child.value is String || child.value is Substring || child.value is Character
                           || child.value is [Character] || child.value is [UInt16], "\(label) holds text")
        }
        XCTAssertEqual(labels, ["gen", "bundleID", "processID", "element", "location", "length", "fingerprint",
                                "original", "originalCaret", "from", "to"],
                       "a new field must be checked here before it is added")
        XCTAssertTrue(rec.original == "akuo vh, nhv", "only the replaced range, not the whole box")
        XCTAssertEqual(rec.fingerprint.count, 32)
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("שלום"))
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("akuo"))

        // P3-35 QA (owner): no timer; the first key, click or focus change after the convert drops it (and its text).
        sut.forgetUndoRecord()
        XCTAssertNil(sut.lastRun)
    }

    // MARK: - Every new path finishes exactly once, last

    @TextActor func testEveryRunPathFinishesExactlyOnceAndLast() async {
        struct Case {
            let name: String
            let run: @TextActor (ConvertControllerRunTests, UInt64) async -> Void
        }
        let cases: [Case] = [
            Case(name: "AX run ≠ buffer") { t, g in
                let (sut, _, _) = t.real(FakeTextField("שלום akuo"))
                await sut.handle(t.request(t.buffer([], current: "vh", in: IDs.abc), gen: g), layouts: t.layouts)
            },
            Case(name: "AX run == buffer, switch off") { t, g in
                let (sut, _, _) = t.real(FakeTextField("akuo"))
                await sut.handle(t.request(t.buffer([], current: "akuo", in: IDs.abc), gen: g, switchAfter: false),
                                 layouts: t.layouts)
            },
            Case(name: "record undo") { t, g in
                let (sut, _, _) = t.real(FakeTextField("akuo"))
                await sut.handle(t.request(t.empty(), gen: g - 1), layouts: t.layouts)
                t.log.clear()
                await sut.handle(t.request(t.empty(untouched: g - 1), gen: g), layouts: t.layouts)
            },
            Case(name: "keys, kept") { t, g in
                let (sut, _) = t.scripted()
                await sut.handle(t.request(t.buffer(["akuo"], current: "vh", in: IDs.abc), gen: g,
                                           bundleID: t.terminal), layouts: t.layouts)
            },
            Case(name: "runTooLong") { t, g in   // P3-35: one word bigger than the field cap
                let (sut, _, _) = t.real(FakeTextField(String(repeating: "a",
                                                              count: ReplacementPlanner.maxFieldReadChars + 1)))
                await sut.handle(t.request(t.empty(), gen: g), layouts: t.layouts)
            },
            Case(name: "fieldUnreadable") { t, g in
                let (sut, r) = t.scripted()
                r.focus = nil
                await sut.handle(t.request(t.empty(), gen: g), layouts: t.layouts)
            },
            Case(name: "layouts unavailable, empty") { t, g in
                let (sut, _) = t.scripted()
                await sut.handle(t.request(t.empty(), gen: g), layouts: nil)
            },
            Case(name: "layouts unavailable, buffer") { t, g in
                let (sut, _) = t.scripted()
                await sut.handle(t.request(t.buffer([], current: "akuo", in: IDs.abc), gen: g), layouts: nil)
            },
            Case(name: "nothing to convert") { t, g in
                let (sut, _, _) = t.real(FakeTextField("123"))
                await sut.handle(t.request(t.empty(), gen: g), layouts: t.layouts)
            },
            Case(name: "abandoned AX run") { t, g in
                t.watcher.claimAnswer = false
                let (sut, _, _) = t.real(FakeTextField("akuo"))
                await sut.handle(t.request(t.empty(), gen: g), layouts: t.layouts)
            },
            Case(name: "halted AX run") { t, g in
                let field = FakeTextField("akuo")
                field.writeBehavior = .garble
                let (sut, _, _) = t.real(field)
                await sut.handle(t.request(t.empty(), gen: g), layouts: t.layouts)
            },
        ]
        for (i, c) in cases.enumerated() {
            log.clear()
            watcher.claimAnswer = true
            let gen = UInt64(100 + 10 * i)
            await c.run(self, gen)
            XCTAssertEqual(log.finishes.count, 1, c.name)
            if case let .finish(g, _, after, renderedIn) = log.finishes.first {
                XCTAssertEqual(g, gen, c.name)
                XCTAssertFalse(renderedIn != nil && after?.isEmpty == false, "\(c.name): X5 invariant")
            }
            XCTAssertEqual(log.entries.last.map { if case .finish = $0 { true } else { false } }, true,
                           "\(c.name): the finish is the last thing done")
        }
    }
}
