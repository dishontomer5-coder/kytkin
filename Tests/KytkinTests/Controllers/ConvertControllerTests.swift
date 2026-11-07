// P2-21: ConvertController (001 §3 flow (c)) with fakes only: every outcome ends with exactly one finish, the
// B3 claim is the KeyWatcher's for the right generation, selection vs last word, the pair direction, the
// after-convert switch (on/off, failing, keeping the buffer), toggle-only, Secure Input / secure fields, stale and
// cancelled requests, the beep, the buffer-after semantics, and that no text outlives a run.

import XCTest

final class ConvertControllerTests: XCTestCase {
    private let app = "com.apple.TextEdit"
    private let akuo = ConvertFixtures.strokes("akuo")

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

    @TextActor private func make(_ replacer: ScriptedReplacer,
                                 caps: ReplacementCapabilities = ReplacementCapabilities()) -> ConvertController {
        let log = self.log!
        return ConvertController(keyWatcher: watcher, clock: clock, capabilities: caps,
                                 beep: { log.add(.beep) }, makeReplacer: { replacer },
                                 switchLanguage: switches.hook)
    }

    @TextActor private func field(selection: String? = nil, secure: Bool = false, marked: Bool = false,
                                  settable: Bool = true, readsBeforeCaret: Bool = false) -> ScriptedReplacer {
        let r = ScriptedReplacer(log: log)
        r.focus = FocusInfo(role: secure ? FocusInfo.secureTextFieldRole : "AXTextArea", isSecure: secure,
                            hasMarkedText: marked, selTextSettable: settable, selRangeSettable: settable,
                            selection: selection, canReadBeforeCaret: readsBeforeCaret)
        return r
    }

    private func word(_ strokes: [Stroke], in source: InputSourceID?) -> WordSnapshot {
        WordSnapshot(strokes: strokes, previousWords: [], renderedIn: source, isValid: !strokes.isEmpty)
    }

    private var empty: WordSnapshot { WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false) }

    private func request(_ snapshot: WordSnapshot? = nil, gen: UInt64 = 1, mode: ConvertRequest.Mode = .convert,
                         bundleID: String? = nil, current: InputSourceID = IDs.abc,
                         switchAfter: Bool = true) -> ConvertRequest {
        ConvertRequest(snapshot: snapshot ?? empty, gen: gen, bundleID: bundleID ?? app, mode: mode,
                       pair: ConvertFixtures.pair, currentSource: current, switchAfterConvert: switchAfter)
    }

    private func assertOneFinish(_ gen: UInt64, rendering: InputSourceID? = nil, after: [Stroke]? = nil,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(log.finishes, [.finish(gen: gen, newRendering: rendering, bufferAfter: after)],
                       file: file, line: line)
    }

    // MARK: - Last word (buffer strokes)

    @TextActor func testLastWordRendersTheStrokesInTheOtherLayoutAndKeepsTheWholeBuffer() async {
        let f = field()
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 7), layouts: ConvertFixtures.layouts)

        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(f.writes.map(\.old), ["akuo"])
        XCTAssertEqual(f.writes.map(\.new), ["שלום"])
        // Claim (gen 7) before the first write, then the switch (keeping the buffer), then the one finish.
        XCTAssertEqual(log.entries, [.focus, .claim(gen: 7), .perform(.backspaceAndType(count: 4)), .end, .end,
                                     .switchTo(IDs.hebrew, keepsBuffer: true),
                                     .finish(gen: 7, newRendering: IDs.hebrew, bufferAfter: nil)])
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testDoubleShiftAgainConvertsBack() async {
        let f = field()
        let sut = make(f)
        await sut.handle(request(word(akuo, in: IDs.abc), gen: 1), layouts: ConvertFixtures.layouts)
        // The tap now holds the same strokes, rendered in Hebrew (bufferAfter + newRendering above).
        let back = await sut.handle(request(word(akuo, in: IDs.hebrew), gen: 2, current: IDs.hebrew),
                                    layouts: ConvertFixtures.layouts)
        XCTAssertEqual(back, .converted(to: IDs.abc, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(f.writes.map(\.old), ["akuo", "שלום"])
        XCTAssertEqual(f.writes.map(\.new), ["שלום", "akuo"])
    }

    /// P2-59c (X5): switch off → the buffer is kept, re-rendered in the target while the input source stays.
    @TextActor func testSwitchAfterConvertOffKeepsTheBufferRenderedInTheTarget() async {
        let sut = make(field())
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 3, switchAfter: false),
                                   layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: false))
        XCTAssertTrue(log.switches.isEmpty)
        // The layout stays ABC while the word on screen is Hebrew: the kept buffer shows in Hebrew.
        XCTAssertEqual(log.finishes, [.finish(gen: 3, newRendering: nil, bufferAfter: nil, renderedIn: IDs.hebrew)])
    }

    @TextActor func testAFailedSwitchDoesNotClaimTheNewRendering() async {
        switches.setAnswer(false)
        let sut = make(field())
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 4), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: false))
        // P2-59c: the text is converted, the source isn't: the kept buffer shows in Hebrew (`bufferRenderedIn`).
        XCTAssertEqual(log.finishes, [.finish(gen: 4, newRendering: nil, bufferAfter: nil, renderedIn: IDs.hebrew)])
    }

    @TextActor func testUnknownRenderingUsesTheCurrentSource() async {
        let f = field()
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: nil), gen: 1, current: IDs.hebrew),
                                   layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(f.writes.map(\.old), ["שלום"])
    }

    /// P2-21 QA: Hebrew finals and the punctuation keys that are letters in Hebrew; digits stay; one Backspace per key.
    @TextActor func testFinalsPunctuationAndDigitsConvertKeyForKey() async {
        let f = field()
        let sut = make(f)
        let keys = ConvertFixtures.strokes("lo,.;i1")
        let out = await sut.handle(request(word(keys, in: IDs.hebrew), gen: 1, current: IDs.hebrew),
                                   layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .backspaceAndType(count: 7), switched: true))
        XCTAssertEqual(f.writes.map(\.old), ["ךםתץףן1"])
        XCTAssertEqual(f.writes.map(\.new), ["lo,.;i1"])
    }

    /// P2-21 QA: a niqqud typed on the Option layer joins the letter before it; the Backspace count would depend on
    /// the app, so the buffered word goes through the AX path (exact range) instead of backspace × graphemes.
    @TextActor func testACombiningMarkInTheBufferUsesTheAXPath() async {
        let f = field(readsBeforeCaret: true)
        f.foundWord = "שָ"
        let sut = make(f)
        let keys = [Stroke(keyCode: 0, layer: .plain), Stroke(keyCode: 13, layer: .option)]
        await sut.handle(request(word(keys, in: IDs.hebrew), gen: 1, current: IDs.hebrew),
                         layouts: ConvertFixtures.layouts)
        XCTAssertFalse(log.performs.contains { if case .backspaceAndType = $0 { true } else { false } })
        XCTAssertEqual(log.performs.first, .axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars))
        assertOneFinish(1, rendering: nil, after: log.claims.isEmpty ? nil : [])
    }

    @TextActor func testALayoutOutsideThePairBeepsAndWritesNothing() async {
        let sut = make(field())
        let out = await sut.handle(request(word(akuo, in: IDs.russian), gen: 2), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.notInPair))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertTrue(log.performs.isEmpty)
        assertOneFinish(2)
    }

    @TextActor func testADeadKeyInTheBufferFallsBackToTheAXPath() async {
        let f = field(readsBeforeCaret: true)
        f.foundWord = "akuo"
        let sut = make(f)
        let dead = [Stroke(keyCode: 14, layer: .option)] + akuo   // ⌥E on ABC is a dead key
        let out = await sut.handle(request(word(dead, in: IDs.abc), gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(log.performs, [.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars),
                                      .axWriteSelection(verify: true)])
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        // An AX-found run doesn't make the strokes describe the screen: the finish forgets the buffer (`[]`). P2-59c:
        // the switch still keeps the processor from resetting, so `untouchedSinceConvert` survives for the X6 undo.
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: true)])
        assertOneFinish(1, rendering: nil, after: [])
    }

    // MARK: - Selection

    @TextActor func testSelectionConvertGuessesTheLayoutFromTheText() async {
        let f = field(selection: "akuo")
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 5), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.writes.map(\.new), ["שלום"])
        XCTAssertEqual(log.claims, [5])
        // A selection convert never keeps the buffer.
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        assertOneFinish(5, rendering: nil, after: [])
    }

    @TextActor func testHebrewSelectionConvertsToEnglishWhateverTheCurrentLayout() async {
        let f = field(selection: "יןת ים׳ שרק טםו?")
        let sut = make(f)
        let out = await sut.handle(request(gen: 1, current: IDs.hebrew), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.writes.map(\.new), ["hi, how are you?"])
    }

    @TextActor func testSelectionFallsThroughToTypingOver() async {
        let f = field(selection: "akuo")
        f.results[.axWrite] = StepOutcome(verdict: .failedVerify, fieldUntouched: true)
        let sut = make(f)
        let out = await sut.handle(request(gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .typeOverSelection, switched: true))
        XCTAssertEqual(log.claims, [1], "claimed once, before the first write")
        XCTAssertTrue(sut.capabilities.isAXWriteBroken(for: app), "the verdict reached the session cache")
    }

    @TextActor func testAnUnconvertibleSelectionBeepsAndNeverClaims() async {
        let sut = make(field(selection: "1234"))
        let out = await sut.handle(request(gen: 9), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.notConvertible)))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertTrue(log.switches.isEmpty)
        assertOneFinish(9)
    }

    @TextActor func testTerminalSelectionIsRefusedWithABeep() async {
        let sut = make(field(selection: "akuo"))
        let out = await sut.handle(request(gen: 2, bundleID: "com.apple.Terminal"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.terminalSelection))))
        XCTAssertEqual(log.beeps, 1)
        assertOneFinish(2)
    }

    // MARK: - Every outcome finishes exactly once

    @TextActor func testRefusedSecureFieldBeepsAndFinishes() async {
        let sut = make(field(secure: true))
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 11), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.secureField))))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertTrue(log.switches.isEmpty, "a password field is never touched, not even the language")
        assertOneFinish(11)
    }

    @TextActor func testComposingAndUnknownFocusAreRefused() async {
        let composing = make(field(marked: true))
        let a = await composing.handle(request(word(akuo, in: IDs.abc), gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(a, .noop(.replacement(.refused(.composing))))

        let unknown = ScriptedReplacer(log: log)   // focus nil: AX couldn't tell
        let b = await make(unknown).handle(request(word(akuo, in: IDs.abc), gen: 2), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(b, .noop(.replacement(.refused(.focusUnknown))))
        XCTAssertEqual(log.beeps, 2)
        XCTAssertEqual(log.finishes, [.finish(gen: 1, newRendering: nil, bufferAfter: nil),
                                      .finish(gen: 2, newRendering: nil, bufferAfter: nil)])
    }

    @TextActor func testAbandonedIsSilentAndWritesNothing() async {
        watcher.claimAnswer = false   // the 400 ms deadline already flushed the held keys
        let f = field()
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 12), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.abandoned)))
        XCTAssertEqual(log.claims, [12])
        XCTAssertTrue(log.performs.isEmpty)
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.switches.isEmpty)
        assertOneFinish(12)
    }

    @TextActor func testHaltedBeepsAndDropsTheWord() async {
        let f = field()
        f.results[.backspace] = StepOutcome(verdict: .unavailable, fieldUntouched: false)
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 13), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.halted(after: .backspaceAndType(count: 4)))))
        XCTAssertEqual(log.beeps, 1)
        assertOneFinish(13, after: [])
    }

    @TextActor func testExhaustedBeeps() async {
        let f = field(selection: "akuo")
        f.results[.axWrite] = StepOutcome(verdict: .unavailable, fieldUntouched: true)
        f.results[.typeOver] = StepOutcome(verdict: .unavailable, fieldUntouched: true)
        let sut = make(f)
        let out = await sut.handle(request(gen: 14), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.exhausted)))
        XCTAssertEqual(log.beeps, 1)
        assertOneFinish(14)
    }

    @TextActor func testTimedOutBeeps() async {
        let f = field(selection: "akuo")
        f.results[.axWrite] = StepOutcome(verdict: .unavailable, fieldUntouched: true)
        let clock = self.clock!
        f.onPerform = { clock.advance(byMilliseconds: 500) }   // a slow app: the 400 ms budget runs out
        let sut = make(f)
        let out = await sut.handle(request(gen: 15), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.timedOut)))
        XCTAssertEqual(log.beeps, 1)
        assertOneFinish(15)
    }

    @TextActor func testLayoutsUnavailableWithABufferBeepsAndFinishes() async {
        let f = field(selection: "akuo")
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 16), layouts: nil)
        XCTAssertEqual(out, .noop(.layoutsUnavailable))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertEqual(log.focusReads, 0)
        XCTAssertTrue(log.switches.isEmpty)
        assertOneFinish(16)
    }

    /// P2-54(a): no maps and nothing remembered: the gesture just switches the language, silently.
    @TextActor func testLayoutsUnavailableWithAnEmptyBufferJustSwitches() async {
        let sut = make(field())
        let out = await sut.handle(request(gen: 16), layouts: nil)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .layoutsUnavailable))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertEqual(log.focusReads, 0)
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        assertOneFinish(16)
    }

    @TextActor func testCancelledBeforeWorkStillFinishes() async {
        let sut = make(field(selection: "akuo"))
        let r = request(gen: 17)
        let task = Task { @TextActor () -> ConvertOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await sut.handle(r, layouts: ConvertFixtures.layouts)
        }
        let out = await task.value
        XCTAssertEqual(out, .noop(.cancelled))
        XCTAssertEqual(log.focusReads, 0)
        assertOneFinish(17)
    }

    @TextActor func testStaleGenerationIsIgnoredButFinished() async {
        let f = field(selection: "akuo")
        let sut = make(f)
        await sut.handle(request(gen: 5), layouts: ConvertFixtures.layouts)
        log.clear()
        let late = await sut.handle(request(gen: 3), layouts: ConvertFixtures.layouts)
        let again = await sut.handle(request(gen: 5), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(late, .noop(.staleGeneration))
        XCTAssertEqual(again, .noop(.staleGeneration))
        XCTAssertEqual(log.entries, [.finish(gen: 3, newRendering: nil, bufferAfter: nil),
                                     .finish(gen: 5, newRendering: nil, bufferAfter: nil)],
                       "no focus read, no claim, no write, no switch, no beep")
    }

    @TextActor func testEveryOutcomeFinishesExactlyOnce() async {
        // One run per ReplacementOutcome.Result (and the toggle), each must leave exactly one finish for its gen.
        struct Case { let name: String; let setup: (ScriptedReplacer, ConvertKeyWatcher) -> Void
                      let snapshot: WordSnapshot? }
        let cases: [Case] = [
            Case(name: "replaced", setup: { _, _ in }, snapshot: word(akuo, in: IDs.abc)),
            Case(name: "abandoned", setup: { _, w in w.claimAnswer = false }, snapshot: word(akuo, in: IDs.abc)),
            Case(name: "refused", setup: { f, _ in f.focus = nil }, snapshot: word(akuo, in: IDs.abc)),
            Case(name: "notConvertible", setup: { f, _ in f.focus = self.focus(selection: "123") }, snapshot: nil),
            Case(name: "halted", setup: { f, _ in
                f.results[.backspace] = StepOutcome(verdict: .unavailable, fieldUntouched: false) },
                 snapshot: word(akuo, in: IDs.abc)),
            Case(name: "exhausted", setup: { f, _ in
                f.results[.backspace] = StepOutcome(verdict: .unavailable, fieldUntouched: true) },
                 snapshot: word(akuo, in: IDs.abc)),
            Case(name: "timedOut", setup: { [clock] f, _ in
                f.focus = self.focus(selection: "akuo")
                f.results[.axWrite] = StepOutcome(verdict: .unavailable, fieldUntouched: true)
                f.onPerform = { clock!.advance(byMilliseconds: 500) } }, snapshot: nil),
            Case(name: "nothing to convert", setup: { _, _ in }, snapshot: nil),
        ]
        for (i, c) in cases.enumerated() {
            log.clear()
            watcher.claimAnswer = true
            let f = field()
            c.setup(f, watcher)
            let gen = UInt64(100 + i)
            _ = await make(f).handle(request(c.snapshot, gen: gen), layouts: ConvertFixtures.layouts)
            XCTAssertEqual(log.finishes.count, 1, c.name)
            if case let .finish(g, _, _, _) = log.finishes.first { XCTAssertEqual(g, gen, c.name) }
            XCTAssertEqual(log.entries.last.map { if case .finish = $0 { true } else { false } }, true,
                           "\(c.name): the finish is the last thing done")
        }
    }

    // MARK: - Toggle-only and nothing to convert

    @TextActor func testToggleOnlyModeSwitchesTheLanguageAndTouchesNoText() async {
        let f = field(selection: "akuo")
        let sut = make(f)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 20, mode: .toggleOnly), layouts: nil)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .toggleMode))
        XCTAssertEqual(log.focusReads, 0, "no AX at all in toggle-only mode (Secure Input, no Accessibility)")
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        assertOneFinish(20)

        log.clear()
        let back = await sut.handle(request(gen: 21, mode: .toggleOnly, current: IDs.hebrew), layouts: nil)
        XCTAssertEqual(back, .toggledOnly(to: IDs.abc, because: .toggleMode))
    }

    @TextActor func testToggleOnlyIgnoresTheSwitchAfterConvertSetting() async {
        let sut = make(field())
        let out = await sut.handle(request(gen: 1, mode: .toggleOnly, switchAfter: false), layouts: nil)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .toggleMode))
    }

    @TextActor func testToggleFromALayoutOutsideThePairBeeps() async {
        let sut = make(field())
        let out = await sut.handle(request(gen: 1, mode: .toggleOnly, current: IDs.russian), layouts: nil)
        XCTAssertEqual(out, .noop(.notInPair))
        XCTAssertEqual(log.beeps, 1)
        XCTAssertTrue(log.switches.isEmpty)
        assertOneFinish(1)
    }

    @TextActor func testAFailedToggleBeeps() async {
        switches.setAnswer(false)
        let sut = make(field())
        let out = await sut.handle(request(gen: 1, mode: .toggleOnly), layouts: nil)
        XCTAssertEqual(out, .noop(.switchFailed))
        XCTAssertEqual(log.beeps, 1)
        assertOneFinish(1)
    }

    @TextActor func testNothingToConvertJustSwitches() async {
        // No selection, empty buffer, and the app can't read before the caret: the planner says bufferStale.
        let sut = make(field())
        let out = await sut.handle(request(gen: 30), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertEqual(log.beeps, 0)
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertEqual(log.switches, [.switchTo(IDs.hebrew, keepsBuffer: false)])
        assertOneFinish(30)
    }

    @TextActor func testNothingBeforeTheCaretJustSwitches() async {
        let f = field(readsBeforeCaret: true)
        f.results[.read] = StepOutcome.unavailable   // caret right after a space / at the start of the field
        let sut = make(f)
        let out = await sut.handle(request(gen: 31), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.claims.isEmpty)
        XCTAssertEqual(log.beeps, 0)
    }

    @TextActor func testDigitsOnlyLastWordJustSwitches() async {
        let sut = make(field())
        let out = await sut.handle(request(word(ConvertFixtures.strokes("123"), in: IDs.abc), gen: 32),
                                   layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
        XCTAssertTrue(log.claims.isEmpty)
    }

    @TextActor func testTerminalLastWordWithAnEmptyBufferJustSwitches() async {
        let sut = make(field(readsBeforeCaret: true))
        let out = await sut.handle(request(gen: 33, bundleID: "com.apple.Terminal"), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .toggledOnly(to: IDs.hebrew, because: .nothingToConvert))
    }

    @TextActor func testStaleBufferConvertsTheWordBeforeTheCaret() async {
        let f = field(readsBeforeCaret: true)
        f.foundWord = "שלום"
        let sut = make(f)
        let out = await sut.handle(request(gen: 34, current: IDs.hebrew), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.abc, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(f.writes.map(\.new), ["akuo"])
        XCTAssertEqual(log.claims, [34])
    }

    // MARK: - Method hints (Settings → Apps)

    @TextActor func testOverridesReachTheCapabilitiesAndCanBeRemoved() async {
        let sut = make(field(selection: "akuo"))
        sut.setMethodHintOverrides([app: .disabled])
        XCTAssertEqual(sut.capabilities.method(for: app), .disabled)
        let out = await sut.handle(request(gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .noop(.replacement(.refused(.disabledForApp))))
        sut.setMethodHintOverrides([:])
        XCTAssertEqual(sut.capabilities.method(for: app), .auto)
        sut.setMethodHintOverrides(["com.apple.Notes": .keysOnly])
        XCTAssertEqual(sut.capabilities.method(for: "com.apple.Notes"), .keysOnly, "an override beats the seed")
        // P2-25 QA (001 §12 T1): except in a terminal, where only "off" overrides the terminal class.
        sut.setMethodHintOverrides(["com.apple.Terminal": .auto])
        XCTAssertEqual(sut.capabilities.method(for: "com.apple.Terminal"), .terminal)
    }

    // MARK: - Privacy

    @TextActor func testNoTextOutlivesARun() async {
        let f = field(selection: "akuo")
        let sut = make(f)
        await sut.handle(request(word(akuo, in: IDs.abc), gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertFalse(f.holdsText, "endReplacement dropped everything the replacer held")
        XCTAssertEqual(log.entries.filter { $0 == .end }.count, 2, "the chain ends it, and so does the controller")
        // The controller keeps no text: no stored property holds a String (or anything containing one).
        XCTAssertFalse(Self.containsString(Mirror(reflecting: sut)), "ConvertController must not retain text")
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("akuo"))
        XCTAssertFalse(String(describing: sut.lastOutcome as Any).contains("שלום"))
    }

    // MARK: - With the real executor (fake AX field + recording poster)

    /// P2-59b bridge: in a readable field the AX run goes first (001 §12.3 X4), even with a valid buffer.
    @TextActor func testRunThroughTheRealExecutorGoesThroughAXFirst() async {
        let textField = FakeTextField("שלום akuo vh, nhv")
        let poster = RecordingPoster()
        let log = self.log!
        let executor = ReplacementExecutor(focusProvider: FakeFocusProvider(textField), poster: poster)
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        let out = await sut.handle(request(word(ConvertFixtures.strokes("nhv"), in: IDs.abc), gen: 1),
                                   layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(textField.text, "שלום שלום הית מיה")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(log.claims, [1])
    }

    @TextActor func testLastWordThroughTheRealExecutor() async {
        let textField = FakeTextField("hello akuo")
        textField.supportsStringForRangeValue = false   // P2-59: unreadable, so the buffer's keys
        let poster = RecordingPoster()
        let log = self.log!
        let executor = ReplacementExecutor(focusProvider: FakeFocusProvider(textField), poster: poster)
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        let out = await sut.handle(request(word(akuo, in: IDs.abc), gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .backspaceAndType(count: 4), switched: true))
        XCTAssertEqual(poster.backspaceCount, 4)
        XCTAssertEqual(poster.typed, "שלום")
    }

    @TextActor func testSelectionThroughTheRealExecutor() async {
        let textField = FakeTextField("hello akuo world", selection: TextRange(location: 6, length: 4))
        let poster = RecordingPoster()
        let log = self.log!
        let executor = ReplacementExecutor(focusProvider: FakeFocusProvider(textField), poster: poster)
        let sut = ConvertController(keyWatcher: watcher, clock: clock, beep: { log.add(.beep) },
                                    makeReplacer: { executor }, switchLanguage: switches.hook)
        let out = await sut.handle(request(gen: 1), layouts: ConvertFixtures.layouts)
        XCTAssertEqual(out, .converted(to: IDs.hebrew, by: .axWriteSelection(verify: true), switched: true))
        XCTAssertEqual(textField.text, "hello שלום world")
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - Private

    private func focus(selection: String?) -> FocusInfo {
        FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
                  selRangeSettable: true, selection: selection, canReadBeforeCaret: false)
    }

    /// Bundle IDs (in the capabilities) and input-source IDs (in the outcome) are allowed; typed text is not.
    private static func containsString(_ mirror: Mirror) -> Bool {
        for child in mirror.children {
            if child.label == "capabilities" || child.label == "appliedOverrides" || child.value is InputSourceID {
                continue
            }
            if child.value is String || child.value is Substring || child.value is Character { return true }
            if child.value is WordSnapshot || child.value is FocusInfo { return true }
            let m = Mirror(reflecting: child.value)
            if m.displayStyle == .struct || m.displayStyle == .tuple || m.displayStyle == .optional
                || m.displayStyle == .enum, containsString(m) { return true }
        }
        return false
    }
}
