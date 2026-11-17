// P2-59c: ConvertController's run flow (001 §12.3 X4–X7, X8 "Controller"), with fakes only: the AX run through the
// real executor on a FakeTextField, the key path on a scripted replacer, the X5 buffer-after table, the switch target,
// `.runTooLong`, the P2-54(a) silent switch, and the finish-exactly-once invariant across the new paths.
// P3-35: a readable field now converts the whole text box (`axReadField`, `BoxConversion`); the tests below that
// asserted the P2-59/P3-33 run-before-caret behaviour are changed to the whole-box behaviour (marked P3-35).
// P3-40 (owner 2026-11-11): no undo. The X6 `LastRun` tests (forward/back/forward, every refusal, the record's fields)
// are replaced by "a second double-Shift converts the whole box again to the other language" and "no text is kept".

import XCTest

final class ConvertControllerRunTests: XCTestCase {
    private let app = "com.apple.TextEdit"
    private let terminal = "com.apple.Terminal"
    /// P3-58 QA: the keys-only app of these tests (chat apps never use keys since P3-58, so Chrome stands in).
    private let slack = "com.google.Chrome"
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
    private func buffer(_ words: [String], gaps: [Int]? = nil, current: String, in source: InputSourceID?)
        -> WordSnapshot {
        let strokes = ConvertFixtures.strokes(current)
        return WordSnapshot(strokes: strokes, previousWords: words.map(ConvertFixtures.strokes), renderedIn: source,
                            isValid: !strokes.isEmpty, gaps: gaps)
    }

    private func empty(in source: InputSourceID = IDs.abc) -> WordSnapshot {
        WordSnapshot(strokes: [], previousWords: [], renderedIn: source, isValid: false)
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
        // X5: the AX run ≠ the buffer → forget it; the finish states that, so the switch doesn't reset the processor.
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: [])])
    }

    @TextActor func testAnAXRunEqualToTheBufferKeepsTheWholeBufferReRendered() async {
        let field = FakeTextField("שלום akuo vh")
        let (sut, _, _) = real(field)
        let out = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הי")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
    }

    /// P3-40: the second double-Shift converts the whole box to the other language (it was the undo, `שלום akuo vh`).
    @TextActor func testAnAXRunEqualToTheBufferWithSwitchOffUsesBufferRenderedInThenConvertsTheBoxAgain() async {
        let field = FakeTextField("שלום akuo vh")
        let (sut, _, _) = real(field)
        await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.abc), gen: 1, switchAfter: false),
                         layouts: layouts)
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil, renderedIn: IDs.hebrew)])
        XCTAssertEqual(field.text, "שלום שלום הי")

        // The processor now snapshots the kept buffer in Hebrew while the source stays ABC.
        log.clear()
        let back = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.hebrew), gen: 2,
                                            switchAfter: false), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axRun, switched: false))
        XCTAssertEqual(field.text, "akuo akuo vh", "the whole box, now all Hebrew, in English")
        XCTAssertEqual(log.finishes, [.finish(gen: 2, newRendering: nil, bufferAfter: [])],
                       "the box range ≠ the kept buffer: forgotten")
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

    /// P3-33: a long multi-line run (≈ 3,000 units over 50 lines) converts whole. P3-40: double-Shift again converts
    /// the whole box (every line, the Hebrew first line too) to English; it no longer restores the original.
    @TextActor func testALongMultiLineRunConvertsWholeAndAgainToTheOtherLanguage() async {
        let line = String(repeating: "akuo ", count: 12) + "\n"          // 61 units
        let original = "שלום\n" + String(repeating: line, count: 50) + "vh"
        let field = FakeTextField(original)
        let (sut, _, poster) = real(field)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: axRun, switched: true))
        let converted = "שלום\n" + String(repeating: String(repeating: "שלום ", count: 12) + "\n", count: 50) + "הי"
        XCTAssertTrue(field.text == converted, "the whole run, every line")
        let back = await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew),
                                    layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: axRun, switched: true))
        XCTAssertTrue(field.text == "akuo\n" + String(repeating: line, count: 50) + "vh", "all English now")
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
    }

    /// P3-33: a long buffer (100 words, 502 keys: what the owner types in Slack before Return) converts whole by keys,
    /// in one Backspace count. P3-40: the kept buffer (all Hebrew now) converts to English on the next double-Shift,
    /// which is what a fresh convert of that text gives (the strokes keep capitals exact too).
    @TextActor func testKeysOnlyAppConvertsALongBufferWholeAndAgainToTheOtherLanguage() async {
        let (sut, r) = scripted(readable: true)
        let words = Array(repeating: "akuo", count: 100)
        let snap = buffer(words, current: "vh", in: IDs.abc)
        let out = await sut.handle(request(snap, gen: 1, bundleID: slack), layouts: layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 502), switched: true))
        XCTAssertTrue(r.writes.map(\.new) == [String(repeating: "שלום ", count: 100) + "הי"], "the whole buffer")
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: IDs.hebrew, bufferAfter: nil)])
        let back = await sut.handle(request(buffer(words, current: "vh", in: IDs.hebrew), gen: 2,
                                            bundleID: slack, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .backspaceAndType(count: 502), switched: true))
        XCTAssertTrue(r.writes.last?.new == String(repeating: "akuo ", count: 100) + "vh", "all English again")
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
        let back = await sut.handle(request(buffer(["akuo"], current: "vh", in: IDs.hebrew), gen: 2,
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
        let back = await sut.handle(request(buffer([], current: "akuo", in: IDs.hebrew), gen: 2,
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
        let out = await sut.handle(request(dead, gen: 1, bundleID: slack), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.noMethod))))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.performs.isEmpty)
    }

    /// P3-41 (owner: in a terminal double-Shift at least switches): the same uncountable buffer in a terminal posts no
    /// keys either, but switches the language instead of beeping.
    @TextActor func testAnUncountableBufferInATerminalJustSwitches() async {
        let (sut, _) = scripted()
        let dead = WordSnapshot(strokes: [Stroke(keyCode: 14, layer: .option)] + ConvertFixtures.strokes("akuo"),
                                previousWords: [], renderedIn: IDs.abc, isValid: true)
        let out = await sut.handle(request(dead, gen: 1, bundleID: terminal), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.performs.isEmpty, "no Backspace count is made up")
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

    /// P3-37 (a) (owner 2026-11-11, P2-54(a)): nothing remembered and nothing may be written: a password field (or a
    /// focus that only reads as one, as a Chromium field can after a click) just switches the language. Nothing is read
    /// or written there; only the input source changes, as under Secure Input. It beeped before.
    @TextActor func testAPasswordFieldWithAnEmptyBufferJustSwitches() async {
        let (sut, r) = scripted()
        r.focus = FocusInfo(role: FocusInfo.secureTextFieldRole, isSecure: true, hasMarkedText: false,
                            selTextSettable: false, selRangeSettable: false, selection: nil)
        let out = await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .fieldUnreadable))
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.performs.isEmpty, "nothing written")
    }

    @TextActor func testAPasswordFieldWithABufferStillBeeps() async {
        let (sut, r) = scripted()
        r.focus = FocusInfo(role: FocusInfo.secureTextFieldRole, isSecure: true, hasMarkedText: false,
                            selTextSettable: false, selRangeSettable: false, selection: nil)
        let out = await sut.handle(request(buffer([], current: "akuo", in: IDs.abc), gen: 1), layouts: layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.secureField))))
        XCTAssertTrue(log.switches.isEmpty)
        XCTAssertEqual(log.beeps, 1)
    }

    // MARK: - P3-40: no undo (replaces the X6 `LastRun` record tests)

    /// Was "undo by the record, forward, back, forward". The owner's example: the second double-Shift converts the
    /// whole (now all-Hebrew) box to English, the third to Hebrew again.
    @TextActor func testForwardAgainAndAgainConvertsTheWholeBoxEachTime() async {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "שלום שלום הית מיה")

        let second = await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(second, .converted(to: IDs.abc, by: axRun, switched: true))
        XCTAssertEqual(field.text, "akuo akuo vh, nhv", "not the original: the whole box in the other language")
        XCTAssertEqual(log.switches.last, .switchTo(IDs.abc, keepsBuffer: true))

        let third = await sut.handle(request(empty(), gen: 3), layouts: layouts)
        XCTAssertEqual(third, .converted(to: IDs.hebrew, by: axRun, switched: true))
        XCTAssertEqual(field.text, "שלום שלום הית מיה")
    }

    /// The same result whatever happened in between (a caret move, another element, an hour): a fresh convert.
    @TextActor func testTheSecondConvertDoesNotDependOnWhatHappenedSince() async {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        field.selection = TextRange(location: 4, length: 0)   // after the first word
        clock.advance(byNanos: 3_600_000_000_000)
        await sut.handle(request(empty(in: IDs.hebrew), gen: 2, current: IDs.hebrew), layouts: layouts)
        XCTAssertEqual(field.text, "akuo שלום הית מיה", "P3-62: only the text before the caret")
        XCTAssertEqual(field.selection, TextRange(location: 4, length: 0), "the caret stays where the user put it")
    }

    @TextActor func testASelectionConvertSwitchesWithoutKeepingTheBuffer() async {
        let field = FakeTextField("hello akuo world", selection: TextRange(location: 6, length: 4))
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        XCTAssertEqual(field.text, "hello שלום world")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
    }

    // MARK: - Privacy

    /// P3-40: was "the record holds only the replaced text, for the undo window". No undo, so the controller keeps no
    /// text between requests: none of its stored properties is text, and the outcome holds steps only.
    @TextActor func testTheControllerKeepsNoTextAfterAConvert() async {
        let field = FakeTextField("שלום akuo vh, nhv")
        let (sut, _, _) = real(field)
        await sut.handle(request(empty(), gen: 1), layouts: layouts)
        var labels: [String] = []
        for child in Mirror(reflecting: sut).children {
            let label = child.label ?? "?"
            labels.append(label)
            XCTAssertFalse(child.value is String || child.value is Substring || child.value is [Character]
                           || child.value is [UInt16], "\(label) holds text")
        }
        XCTAssertFalse(labels.contains("lastRun"), "no undo record")
        // P3-40 QA: and recursively (a struct or tuple holding text, like the old `LastRun`, would fail this).
        XCTAssertFalse(ConvertControllerTests.containsString(Mirror(reflecting: sut)), "no text anywhere inside")
        XCTAssertFalse(labels.contains("lastClip"), "no clipboard undo record")
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("שלום"))
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("akuo"))
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
            Case(name: "second convert (P3-40: was the record undo)") { t, g in
                let (sut, _, _) = t.real(FakeTextField("akuo"))
                await sut.handle(t.request(t.empty(), gen: g - 1), layouts: t.layouts)
                t.log.clear()
                await sut.handle(t.request(t.empty(in: IDs.hebrew), gen: g, current: IDs.hebrew), layouts: t.layouts)
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
