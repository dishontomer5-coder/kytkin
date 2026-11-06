// P2-18: ReplacementChain runs a plan over the executor: fall-through on a read-back mismatch, halting when the
// field state is unknown, verdict reporting to ReplacementCapabilities, the stale-buffer path, the write gate
// (P2-51: AX writes and key posts), and the 400 ms budget.

import XCTest

final class ReplacementChainTests: XCTestCase {
    private let app = "com.apple.TextEdit"
    /// A few Hebrew-on-ABC keys (R6), enough for the words used here.
    private static let map: [Character: Character] = ["a": "ש", "k": "ל", "u": "ו", "o": "ם", ",": "ת", "s": "ד",
                                                      "v": "ה"]
    private let convert: (String) -> String? = { s in
        let out = s.map { ReplacementChainTests.map[$0] ?? ($0.isWhitespace ? $0 : nil) }
        return out.contains(nil) ? nil : String(out.compactMap { $0 })
    }

    private var poster = RecordingPoster()

    @TextActor private func executor(_ f: FakeTextField) -> ReplacementExecutor {
        ReplacementExecutor(focusProvider: FakeFocusProvider(f), poster: poster)
    }

    private func sel(_ location: Int, _ length: Int) -> TextRange { TextRange(location: location, length: length) }

    /// Focus → plan → run, as ConvertController (P2-21) will.
    @TextActor private func convertSelection(_ f: FakeTextField, caps: inout ReplacementCapabilities,
                                             bundle: String? = nil) -> ReplacementOutcome {
        let x = executor(f)
        let focus = x.focusInfo(timeout: ReplacementExecutor.axTimeout)
        let request = ReplacementRequest(kind: .convertSelection, bundleID: bundle ?? app)
        let plan = ReplacementPlanner.plan(request, caps: caps, focus: focus)
        return ReplacementChain.run(plan, on: x, bundleID: bundle ?? app, old: focus?.selection, convert: convert,
                                    capabilities: &caps)
    }

    // MARK: - Selection chain

    @TextActor func testVerifiedAXWriteWinsAndTypesNothing() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "hello שלום world")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertFalse(caps.isAXWriteBroken(for: app))
        XCTAssertFalse(out.shouldBeep)
    }

    @TextActor func testReadBackMismatchFallsThroughToTypingAndIsRemembered() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .silentNoop
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .replaced(by: .typeOverSelection))
        XCTAssertEqual(out.attempts, [.init(step: .axWriteSelection(verify: true), verdict: .failedVerify),
                                      .init(step: .typeOverSelection, verdict: .done)])
        XCTAssertEqual(poster.typed, "שלום")
        // The verdict reached the session cache: the next convert in this app skips AX.
        XCTAssertTrue(caps.isAXWriteBroken(for: app))
        let next = ReplacementPlanner.plan(ReplacementRequest(kind: .convertSelection, bundleID: app), caps: caps,
                                           focus: FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false,
                                                            selTextSettable: true, selRangeSettable: true,
                                                            selection: "akuo"))
        XCTAssertEqual(next, .steps([.typeOverSelection]))
    }

    @TextActor func testUnknownFieldStateAfterAWriteHaltsInsteadOfTyping() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .garble
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(poster.events.isEmpty, "never type over a half-written field")
        XCTAssertTrue(out.shouldBeep)
        XCTAssertTrue(caps.isAXWriteBroken(for: app))
    }

    @TextActor func testUnavailableAXWriteFallsThroughButTeachesNothing() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .fails
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .replaced(by: .typeOverSelection))
        XCTAssertFalse(caps.isAXWriteBroken(for: app))
    }

    @TextActor func testSecureFieldIsRefusedAndNothingHappens() async {
        let f = FakeTextField("akuo", selection: sel(0, 4))
        f.role = FocusInfo.secureTextFieldRole
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .refused(.secureField))
        XCTAssertTrue(out.attempts.isEmpty)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(out.shouldBeep)
    }

    @TextActor func testComposingAndTimeoutAreRefused() async {
        let composing = FakeTextField("akuo", selection: sel(0, 4))
        composing.markedRange = sel(0, 4)
        var caps = ReplacementCapabilities()
        XCTAssertEqual(convertSelection(composing, caps: &caps).result, .refused(.composing))
        let hung = FakeTextField("akuo", selection: sel(0, 4))
        hung.timeouts = [.role]
        XCTAssertEqual(convertSelection(hung, caps: &caps).result, .refused(.focusUnknown))
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testMultiLineSelectionIsNeverTyped() async {
        // AX can't write here, so the planner refuses (§12 T2); and if AX fails verify, nothing is typed.
        let f = FakeTextField("ak\nuo", selection: sel(0, 5))
        f.selTextSettable = false
        var caps = ReplacementCapabilities()
        XCTAssertEqual(convertSelection(f, caps: &caps).result, .refused(.unsafeSelection))
        let g = FakeTextField("ak\nuo", selection: sel(0, 5))
        g.writeBehavior = .silentNoop
        let out = convertSelection(g, caps: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testTerminalSelectionIsRefused() async {
        let f = FakeTextField("akuo", selection: sel(0, 4))
        var caps = ReplacementCapabilities()
        XCTAssertEqual(convertSelection(f, caps: &caps, bundle: "com.apple.Terminal").result,
                       .refused(.terminalSelection))
    }

    @TextActor func testNotConvertibleWritesNothing() async {
        let f = FakeTextField("hello xyz", selection: sel(6, 3))
        var caps = ReplacementCapabilities()
        XCTAssertEqual(convertSelection(f, caps: &caps).result, .notConvertible)
        XCTAssertFalse(f.writes.contains(.selectedText))
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - Last word

    @TextActor func testLastWordWithAValidBufferBackspacesAndTypes() async {
        let f = FakeTextField("hello akuo")
        let x = executor(f)
        let focus = x.focusInfo(timeout: 0.25)
        let snap = WordSnapshot(strokes: (0..<4).map { Stroke(keyCode: UInt16($0), layer: .plain) },
                                previousWords: [], renderedIn: nil, isValid: true)
        let plan = ReplacementPlanner.plan(ReplacementRequest(kind: .convertLastWord, bundleID: app, snapshot: snap,
                                                              typedLength: 4), caps: ReplacementCapabilities(),
                                           focus: focus)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(plan, on: x, bundleID: app, old: "akuo", convert: convert, capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .backspaceAndType(count: 4)))
        XCTAssertEqual(poster.backspaceCount, 4)
        XCTAssertEqual(poster.typed, "שלום")
        XCTAssertTrue(poster.events.allSatisfy { $0.marker == EventOrigin.oursMarker && $0.modifierFlags == 0 })
    }

    @TextActor func testStaleBufferReadsBeforeTheCaretThenWritesThroughAX() async {
        let f = FakeTextField("hello ,usv")
        let x = executor(f)
        let focus = x.focusInfo(timeout: 0.25)
        let plan = ReplacementPlanner.plan(ReplacementRequest(kind: .convertLastWord, bundleID: app),
                                           caps: ReplacementCapabilities(), focus: focus)
        XCTAssertEqual(plan, .steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]))
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(plan, on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "hello תודה")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertNil(x.wordBeforeCaret, "the word read through AX is dropped when the run ends")
    }

    @TextActor func testStaleBufferWithNoWordStops() async {
        let f = FakeTextField("hello ")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(out.attempts.count, 1)
        XCTAssertTrue(f.writes.isEmpty)
    }

    // MARK: - Stale path never leaves a selection behind (P2-18 QA)

    /// Runs the stale-buffer plan on "hello ,usv" (caret at the end) with the given write behavior.
    @TextActor private func staleRun(_ behavior: FakeTextField.WriteBehavior) -> (FakeTextField, ReplacementOutcome) {
        let f = FakeTextField("hello ,usv")
        f.writeBehavior = behavior
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps)
        return (f, out)
    }

    @TextActor func testStaleNoopWriteRestoresTheCaretSoTheNextKeyCantEatTheWord() async {
        let (f, out) = staleRun(.silentNoop)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(f.text, "hello ,usv")
        XCTAssertEqual(f.selection, sel(10, 0), "the word must not stay selected after a failed convert")
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testStaleFailedWriteRestoresTheCaret() async {
        let (f, out) = staleRun(.fails)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(f.text, "hello ,usv")
        XCTAssertEqual(f.selection, sel(10, 0))
    }

    @TextActor func testStaleWriteThatLeavesTheNewWordSelectedEndsWithACaret() async {
        let (f, out) = staleRun(.normalKeepsSelection)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "hello תודה")
        XCTAssertEqual(f.selection, sel(10, 0), "the converted word must not stay selected")
    }

    @TextActor func testStaleGarbledWriteHaltsAndLeavesNoSelection() async {
        let (f, out) = staleRun(.garble)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(f.selection.isCaret)
        XCTAssertTrue(poster.events.isEmpty, "never type after an unknown write")
    }

    @TextActor func testStaleWordChangedBeforeTheWriteIsNotWrittenAndCaretIsRestored() async {
        let f = FakeTextField("hello ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axReadBeforeCaret(maxChars: 64), old: "", new: "").verdict, .done)
        f.units = Array("hello ,usx".utf16)   // the app changed the word between the read and the write
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: ",usv", new: "תודה"), .unavailable)
        XCTAssertEqual(f.text, "hello ,usx")
        XCTAssertEqual(f.selection, sel(10, 0))
    }

    @TextActor func testSelectionPathKeepsTheUsersOwnSelection() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .fails
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: "akuo", new: "שלום"), .unavailable)
        XCTAssertEqual(f.selection, sel(6, 4), "the user's selection is theirs; the next step types over it")
    }

    // MARK: - Gate, budget, cleanup

    @TextActor func testWriteGateIsAskedExactlyOnceAcrossKeySteps() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        poster.failFrom = 0   // the first key step can't post anything, so the chain falls through
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.typeOverSelection, .typeOverSelection]), on: x, bundleID: app,
                                       old: "akuo", convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(asked, 1)
    }

    // P2-51 (001 §12.2 W8): an AX write takes the hold-back commit too.
    @TextActor func testWriteGateIsAskedBeforeAnAXWrite() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        var writesWhenAsked: [AXTextAttribute]?
        let out = ReplacementChain.run(.steps([.axWriteSelection(verify: true), .typeOverSelection]), on: x,
                                       bundleID: app, old: "akuo", convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; writesWhenAsked = f.writes; return true })
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(writesWhenAsked, [], "the claim comes before the AX write")
        XCTAssertEqual(f.writes, [.selectedText])
    }

    @TextActor func testWriteGateIsAskedOnceAcrossAnAXWriteAndTheKeyFallback() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .silentNoop
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axWriteSelection(verify: true), .typeOverSelection]), on: x,
                                       bundleID: app, old: "akuo", convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .replaced(by: .typeOverSelection))
        XCTAssertEqual(asked, 1)
    }

    @TextActor func testWriteGateIsNotAskedAfterTheBudgetRanOut() async {
        // The read step uses up the budget, so the chain stops before its first write and never claims.
        let f = FakeTextField("hello ,usv")
        let clock = FakeClock()
        let slow = SlowReplacer(executor(f), clock: clock, stepNanos: 450_000_000)
        _ = slow.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: slow, bundleID: app, old: nil, convert: convert, capabilities: &caps,
                                       clock: clock, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .timedOut)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(f.writes.isEmpty)
    }

    @TextActor func testWriteGateIsNotAskedForAReadThatFindsNothing() async {
        let f = FakeTextField("hello ")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(asked, 0, "a read-only step never takes the hold-back commit")
    }

    @TextActor func testRefusedWriteGateAbandonsSilently() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axWriteSelection(verify: true), .typeOverSelection]), on: x,
                                       bundleID: app, old: "akuo", convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; return false })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(out.attempts.isEmpty)
        XCTAssertTrue(f.writes.isEmpty, "no AX write once the deadline won")
        XCTAssertEqual(f.text, "hello akuo world")
        XCTAssertEqual(f.selection, sel(6, 4), "the user's selection is left as it was")
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertFalse(caps.isAXWriteBroken(for: app), "an abandoned convert teaches nothing")
        XCTAssertFalse(out.shouldBeep)
    }

    @TextActor func testRefusedWriteGateOnTheStalePathLeavesFieldAndCaretUntouched() async {
        let f = FakeTextField("hello ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps,
                                       mayWrite: { asked += 1; return false })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(asked, 1, "asked after the read, before the range write")
        XCTAssertEqual(out.attempts, [.init(step: .axReadBeforeCaret(maxChars: 64), verdict: .done)])
        XCTAssertTrue(f.writes.isEmpty, "not even the selection range is set: a replayed key would eat the word")
        XCTAssertEqual(f.text, "hello ,usv")
        XCTAssertEqual(f.selection, sel(10, 0))
        XCTAssertNil(x.wordBeforeCaret)
        XCTAssertFalse(out.shouldBeep)
    }

    /// The W8 race: the deadline flush replays the user's held keys while the convert runs. If the flush wins, the
    /// claim says no and the AX write never lands on the text the user just typed.
    @TextActor func testDeadlineFlushBeforeTheClaimMeansNoAXWrite() async {
        let f = FakeTextField("hello ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps,
                                       mayWrite: {
                                           // The flush won: the held key reached the field first.
                                           f.units += Array("x".utf16)
                                           f.selection = TextRange(location: f.units.count, length: 0)
                                           return false
                                       })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(f.text, "hello ,usvx")
        XCTAssertEqual(f.selection, sel(11, 0))
        XCTAssertTrue(f.writes.isEmpty)
    }

    /// If the convert wins the claim, every write and the stale-range check run under it, so no flush can land
    /// between the check and `AXSelectedText`.
    @TextActor func testStalePathClaimsBeforeTheRangeWriteAndTheStaleRangeCheck() async {
        let f = FakeTextField("hello ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var writesWhenAsked: [AXTextAttribute]?
        var readsWhenAsked = 0
        let out = ReplacementChain.run(.steps([.axReadBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps,
                                       mayWrite: {
                                           writesWhenAsked = f.writes
                                           readsWhenAsked = f.reads.count
                                           return true
                                       })
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(writesWhenAsked, [], "claimed before setRange selects the word")
        XCTAssertTrue(f.reads[readsWhenAsked...].contains(.selectedText), "the stale-range check runs after the claim")
        XCTAssertEqual(f.writes.first, .selectedTextRange)
        XCTAssertEqual(f.text, "hello תודה")
    }

    @TextActor func testBudgetStopsTheChain() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .silentNoop
        let clock = FakeClock()
        let slow = SlowReplacer(executor(f), clock: clock, stepNanos: 450_000_000)
        _ = slow.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axWriteSelection(verify: true), .typeOverSelection]), on: slow,
                                       bundleID: app, old: "akuo", convert: convert, capabilities: &caps,
                                       clock: clock)
        XCTAssertEqual(out.result, .timedOut)
        XCTAssertEqual(out.attempts.count, 1)
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testRefusedPlanStillEndsTheReplacement() async {
        let f = FakeTextField("hello akuo", selection: sel(6, 4))
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.refuse(.noMethod), on: x, bundleID: app, old: "akuo", convert: convert,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .refused(.noMethod))
        XCTAssertEqual(x.perform(.typeOverSelection, old: "akuo", new: "שלום"), .unavailable)
    }
}

/// Wraps an executor and moves a fake clock forward on every step, to test the B5 budget.
@TextActor private final class SlowReplacer: TextReplacing {
    private let inner: ReplacementExecutor
    private let clock: FakeClock
    private let stepNanos: UInt64

    init(_ inner: ReplacementExecutor, clock: FakeClock, stepNanos: UInt64) {
        self.inner = inner
        self.clock = clock
        self.stepNanos = stepNanos
    }

    func focusInfo(timeout: Double) -> FocusInfo? { inner.focusInfo(timeout: timeout) }
    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome {
        clock.advance(byNanos: stepNanos)
        return inner.perform(step, old: old, new: new)
    }
    var wordBeforeCaret: String? { inner.wordBeforeCaret }
    func endReplacement() { inner.endReplacement() }
}
