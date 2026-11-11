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

    /// P2-59: the real run scan over the ABC / Apple Hebrew fixtures, as ConvertController locates the run.
    private let locate: (BeforeCaretWindow) -> RunLocation? = { w in
        if case .run(let loc, _) = RunBeforeCaret.scan(w, classify: ConvertFixtures.layouts.runClass) { return loc }
        return nil
    }

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

    // MARK: - Run (P2-59, 001 §12.3 X4)

    /// A buffer snapshot of `count` strokes (the chain only needs it to exist; the text is `old`).
    private func buffer(_ count: Int) -> WordSnapshot {
        WordSnapshot(strokes: (0..<count).map { Stroke(keyCode: UInt16($0), layer: .plain) },
                     previousWords: [], renderedIn: nil, isValid: true)
    }

    private let pairConvert: (String) -> String? = {
        ConvertFixtures.layouts.converter(from: IDs.abc)?.convert($0).text
    }

    @TextActor func testUnreadableFieldBackspacesAndTypesTheBuffer() async {
        let f = FakeTextField("hello akuo")
        f.supportsStringForRangeValue = false
        let x = executor(f)
        let focus = x.focusInfo(timeout: 0.25)
        let plan = ReplacementPlanner.plan(ReplacementRequest(kind: .convertRun, bundleID: app, snapshot: buffer(4),
                                                              typedLength: 4), caps: ReplacementCapabilities(),
                                           focus: focus)
        XCTAssertEqual(plan, .steps([.backspaceAndType(count: 4)]))
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(plan, on: x, bundleID: app, old: "akuo", convert: convert, capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .backspaceAndType(count: 4)))
        XCTAssertEqual(poster.backspaceCount, 4)
        XCTAssertEqual(poster.typed, "שלום")
        XCTAssertTrue(poster.events.allSatisfy { $0.marker == EventOrigin.oursMarker && $0.modifierFlags == 0 })
    }

    @TextActor func testStaleBufferReadsBeforeTheCaretThenWritesThroughAX() async {
        let f = FakeTextField("שלום ,usv")
        let x = executor(f)
        let focus = x.focusInfo(timeout: 0.25)
        let plan = ReplacementPlanner.plan(ReplacementRequest(kind: .convertRun, bundleID: app),
                                           caps: ReplacementCapabilities(), focus: focus)
        XCTAssertEqual(plan, .steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true)]))
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(plan, on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "שלום תודה")
        XCTAssertEqual(f.selection, sel(9, 0))
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertNil(x.wordBeforeCaret, "the run read through AX is dropped when the chain ends")
    }

    /// The owner's example, with the real pair converter: the whole wrong-layout run, one AX write, no keys.
    @TextActor func testOwnersExampleConvertsTheWholeRunThroughAX() async {
        let f = FakeTextField("שלום akuo vh, nhv")
        let x = executor(f)
        let focus = x.focusInfo(timeout: 0.25)
        let plan = ReplacementPlanner.plan(ReplacementRequest(kind: .convertRun, bundleID: app, snapshot: buffer(3),
                                                              typedLength: 3), caps: ReplacementCapabilities(),
                                           focus: focus)
        XCTAssertEqual(plan, .steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                     .backspaceAndType(count: 3)]))
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(plan, on: x, bundleID: app, old: "nhv", convert: pairConvert,
                                       locateRun: locate, capabilities: &caps, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "שלום שלום הית מיה")
        XCTAssertEqual(f.selection, sel(17, 0))
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// The AX write is a no-op with the caret verified back, and the AX run is exactly the buffer's text: the key
    /// fallback runs, under the claim already taken for the AX write.
    @TextActor func testKeyFallbackRunsWhenTheAXRunIsTheBufferAndTheClaimIsNotAskedAgain() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .silentNoop
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        var writesWhenAsked: [AXTextAttribute]?
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps,
                                       mayWrite: { asked += 1; writesWhenAsked = f.writes; return true })
        XCTAssertEqual(out.result, .replaced(by: .backspaceAndType(count: 4)))
        XCTAssertEqual(asked, 1, "one claim, before the AX write, covers the key fallback")
        XCTAssertEqual(writesWhenAsked, [])
        XCTAssertEqual(f.selection, sel(9, 0), "the caret was back before the keys")
        XCTAssertEqual(poster.backspaceCount, 4)
        XCTAssertEqual(poster.typed, "שלום")
    }

    /// The AX run is longer than the buffer (it sees further back): Backspace × buffer would leave half of it.
    @TextActor func testKeyFallbackIsSkippedWhenTheAXRunIsNotTheBuffer() async {
        let f = FakeTextField("שלום akuo vh")
        f.writeBehavior = .silentNoop
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 2)]),
                                       on: x, bundleID: app, old: "vh", convert: pairConvert, locateRun: locate,
                                       capabilities: &caps, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(out.attempts.map(\.step),
                       [.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true)])
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(f.text, "שלום akuo vh")
        XCTAssertEqual(f.selection, sel(12, 0))
    }

    /// P2-59b QA: the AX run is canonically equal to the buffer's text but in another normalization (`e` + U+0301
    /// on screen, `é` in the buffer). Swift's `==` says equal; the key fallback must not trust it: some apps delete
    /// a decomposed character one scalar per Backspace, so the count would be wrong.
    @TextActor func testKeyFallbackIsSkippedWhenTheAXRunIsOnlyCanonicallyEqualToTheBuffer() async {
        let f = FakeTextField("cafe\u{301}")
        f.writeBehavior = .silentNoop
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "caf\u{e9}", convert: { _ in "xxxx" },
                                       locateRun: { w in RunLocation(offset: 0, length: w.text.utf16.count) },
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(out.attempts.map(\.step),
                       [.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true)])
        XCTAssertTrue(poster.events.isEmpty, "no Backspace on a merely canonically-equal run")
        XCTAssertEqual(f.text, "cafe\u{301}")
    }

    /// The run read can't run (no AXStringForRange here): the AX write that depends on it is skipped, not run and
    /// not recorded, and the key step runs on the caller's buffer text.
    @TextActor func testUnavailableReadSkipsTheAXWriteAndRunsTheKeyStep() async {
        let f = FakeTextField("שלום akuo")
        f.supportsStringForRangeValue = false
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .replaced(by: .backspaceAndType(count: 4)))
        XCTAssertEqual(out.attempts, [.init(step: .axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), verdict: .unavailable),
                                      .init(step: .backspaceAndType(count: 4), verdict: .done)])
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(f.writes.isEmpty, "the AX write never ran")
        XCTAssertEqual(poster.typed, "שלום")
    }

    @TextActor func testUnavailableReadWithoutAKeyStepWritesNothing() async {
        let f = FakeTextField("שלום akuo")
        f.supportsStringForRangeValue = false
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(out.attempts.count, 1)
    }

    /// Without a locator the read step can't run; it is just unavailable.
    @TextActor func testReadWithoutALocatorIsUnavailable() async {
        let f = FakeTextField("שלום akuo")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(out.attempts, [.init(step: .axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), verdict: .unavailable)])
        XCTAssertTrue(f.writes.isEmpty)
    }

    @TextActor func testHaltedAXWriteNeverFallsBackToKeys() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .garble
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// X4 strict collapse: the write failed untouched but the run is still selected (the caret can't be put back),
    /// so a Backspace would delete the selection and N − 1 more: halted, no keys.
    @TextActor func testUnverifiedCaretRestoreHaltsAndNeverTypes() async {
        let f = FakeTextField("שלום akuo")
        f.writeBehavior = .silentNoop
        f.rejectsCaretRanges = true
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertTrue(out.shouldBeep)
    }

    @TextActor func testRefusedClaimOnTheRunPathWritesAndTypesNothing() async {
        let f = FakeTextField("שלום akuo")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: x, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps, mayWrite: { asked += 1; return false })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertEqual(f.selection, sel(9, 0))
    }

    @TextActor func testBudgetExpiryBetweenTheRunReadAndTheWriteWritesNothing() async {
        let f = FakeTextField("שלום akuo")
        let clock = FakeClock()
        let slow = SlowReplacer(executor(f), clock: clock, stepNanos: 450_000_000)
        _ = slow.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars), .axWriteSelection(verify: true),
                                               .backspaceAndType(count: 4)]),
                                       on: slow, bundleID: app, old: "akuo", convert: convert, locateRun: locate,
                                       capabilities: &caps, clock: clock, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .timedOut)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertTrue(poster.events.isEmpty)
    }

    /// Every `.convertRun` plan shape the planner returns: the gate is asked once, before the first write, and
    /// never by the read.
    @TextActor func testWriteGateIsAskedOnceBeforeTheFirstWriteOnEveryRunPlanShape() async {
        let read = ReplacementStep.axReadRunBeforeCaret(maxChars: ReplacementPlanner.maxRunReadChars)
        let ax = ReplacementStep.axWriteSelection(verify: true)
        let keys = ReplacementStep.backspaceAndType(count: 4)
        for steps in [[read, ax, keys], [read, ax], [keys]] {
            poster = RecordingPoster()
            poster.failFrom = 0   // the key step fails untouched, so the whole shape runs
            let f = FakeTextField("שלום akuo")
            f.writeBehavior = .silentNoop
            let counting = CountingReplacer(executor(f))
            _ = counting.focusInfo(timeout: 0.25)
            var caps = ReplacementCapabilities()
            var asked = 0
            var performedWhenAsked: [ReplacementStep]?
            var writesWhenAsked: [AXTextAttribute]?
            let out = ReplacementChain.run(.steps(steps), on: counting, bundleID: app, old: "akuo", convert: convert,
                                           locateRun: locate, capabilities: &caps, mayWrite: {
                                               asked += 1
                                               performedWhenAsked = counting.performed
                                               writesWhenAsked = f.writes
                                               return true
                                           })
            XCTAssertEqual(out.result, .exhausted, "\(steps)")
            XCTAssertEqual(asked, 1, "\(steps)")
            XCTAssertEqual(performedWhenAsked, steps.first == read ? [read] : [], "\(steps)")
            XCTAssertEqual(writesWhenAsked, [], "\(steps)")
            XCTAssertEqual(counting.performed, steps, "\(steps)")
            XCTAssertEqual(f.text, "שלום akuo", "\(steps)")
        }
    }

    @TextActor func testStaleBufferWithNoWordStops() async {
        let f = FakeTextField("akuo\t")   // P3-33: a tab still ends the run (a line break no longer does)
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(out.attempts.count, 1)
        XCTAssertTrue(f.writes.isEmpty)
    }

    // MARK: - Stale path never leaves a selection behind (P2-18 QA)

    /// Runs the stale-buffer plan on "שלום ,usv" (caret at the end) with the given write behavior.
    @TextActor private func staleRun(_ behavior: FakeTextField.WriteBehavior) -> (FakeTextField, ReplacementOutcome) {
        let f = FakeTextField("שלום ,usv")
        f.writeBehavior = behavior
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps)
        return (f, out)
    }

    @TextActor func testStaleNoopWriteRestoresTheCaretSoTheNextKeyCantEatTheWord() async {
        let (f, out) = staleRun(.silentNoop)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(f.text, "שלום ,usv")
        XCTAssertEqual(f.selection, sel(9, 0), "the word must not stay selected after a failed convert")
        XCTAssertTrue(poster.events.isEmpty)
    }

    @TextActor func testStaleFailedWriteRestoresTheCaret() async {
        let (f, out) = staleRun(.fails)
        XCTAssertEqual(out.result, .exhausted)
        XCTAssertEqual(f.text, "שלום ,usv")
        XCTAssertEqual(f.selection, sel(9, 0))
    }

    @TextActor func testStaleWriteThatLeavesTheNewWordSelectedEndsWithACaret() async {
        let (f, out) = staleRun(.normalKeepsSelection)
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(f.text, "שלום תודה")
        XCTAssertEqual(f.selection, sel(9, 0), "the converted word must not stay selected")
    }

    @TextActor func testStaleGarbledWriteHaltsAndLeavesNoSelection() async {
        let (f, out) = staleRun(.garble)
        XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)))
        XCTAssertTrue(f.selection.isCaret)
        XCTAssertTrue(poster.events.isEmpty, "never type after an unknown write")
    }

    @TextActor func testStaleWordChangedBeforeTheWriteIsNotWrittenAndCaretIsRestored() async {
        let f = FakeTextField("שלום ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        XCTAssertEqual(x.readRunBeforeCaret(maxChars: 64, locate: locate).verdict, .done)
        f.units = Array("שלום ,usx".utf16)   // the app changed the word between the read and the write
        XCTAssertEqual(x.perform(.axWriteSelection(verify: true), old: ",usv", new: "תודה"), .unavailable)
        XCTAssertEqual(f.text, "שלום ,usx")
        XCTAssertEqual(f.selection, sel(9, 0))
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
        let f = FakeTextField("שלום ,usv")
        let clock = FakeClock()
        let slow = SlowReplacer(executor(f), clock: clock, stepNanos: 450_000_000)
        _ = slow.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: slow, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps,
                                       clock: clock, mayWrite: { asked += 1; return true })
        XCTAssertEqual(out.result, .timedOut)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(f.writes.isEmpty)
    }

    @TextActor func testWriteGateIsNotAskedForAReadThatFindsNothing() async {
        let f = FakeTextField("akuo\t")   // P3-33: a tab still ends the run (a line break no longer does)
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps,
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
        let f = FakeTextField("שלום ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps,
                                       mayWrite: { asked += 1; return false })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(asked, 1, "asked after the read, before the range write")
        XCTAssertEqual(out.attempts, [.init(step: .axReadRunBeforeCaret(maxChars: 64), verdict: .done)])
        XCTAssertTrue(f.writes.isEmpty, "not even the selection range is set: a replayed key would eat the word")
        XCTAssertEqual(f.text, "שלום ,usv")
        XCTAssertEqual(f.selection, sel(9, 0))
        XCTAssertNil(x.wordBeforeCaret)
        XCTAssertFalse(out.shouldBeep)
    }

    /// The W8 race: the deadline flush replays the user's held keys while the convert runs. If the flush wins, the
    /// claim says no and the AX write never lands on the text the user just typed.
    @TextActor func testDeadlineFlushBeforeTheClaimMeansNoAXWrite() async {
        let f = FakeTextField("שלום ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps,
                                       mayWrite: {
                                           // The flush won: the held key reached the field first.
                                           f.units += Array("x".utf16)
                                           f.selection = TextRange(location: f.units.count, length: 0)
                                           return false
                                       })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(f.text, "שלום ,usvx")
        XCTAssertEqual(f.selection, sel(10, 0))
        XCTAssertTrue(f.writes.isEmpty)
    }

    /// If the convert wins the claim, every write and the stale-range check run under it, so no flush can land
    /// between the check and `AXSelectedText`.
    @TextActor func testStalePathClaimsBeforeTheRangeWriteAndTheStaleRangeCheck() async {
        let f = FakeTextField("שלום ,usv")
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var writesWhenAsked: [AXTextAttribute]?
        var readsWhenAsked = 0
        let out = ReplacementChain.run(.steps([.axReadRunBeforeCaret(maxChars: 64), .axWriteSelection(verify: true)]),
                                       on: x, bundleID: app, old: nil, convert: convert, locateRun: locate,
                                       capabilities: &caps,
                                       mayWrite: {
                                           writesWhenAsked = f.writes
                                           readsWhenAsked = f.reads.count
                                           return true
                                       })
        XCTAssertEqual(out.result, .replaced(by: .axWriteSelection(verify: true)))
        XCTAssertEqual(writesWhenAsked, [], "claimed before setRange selects the word")
        XCTAssertTrue(f.reads[readsWhenAsked...].contains(.selectedText), "the stale-range check runs after the claim")
        XCTAssertEqual(f.writes.first, .selectedTextRange)
        XCTAssertEqual(f.text, "שלום תודה")
    }

    // MARK: - Gate over every plan shape the planner can produce (P2-51 QA)

    /// Every write-only chain `ReplacementPlanner.plan` can return. Selection: an optional leading pasteboard
    /// (`preferPaste`), an optional AX write, an optional type-over, an optional trailing pasteboard (P3 opt-in),
    /// not all absent. Last word (valid buffer), auto-fix and undo: backspace + type. The stale path (read, then AX
    /// write) has its own tests above.
    private static let writePlans: [[ReplacementStep]] = {
        let ax = ReplacementStep.axWriteSelection(verify: true)
        return [[ax, .typeOverSelection], [ax], [.typeOverSelection],
                [ax, .typeOverSelection, .pasteboard], [.pasteboard, ax, .typeOverSelection], [.pasteboard, ax],
                [.pasteboard], [.typeOverSelection, .pasteboard], [ax, .pasteboard], [.pasteboard, .typeOverSelection],
                [.backspaceAndType(count: 4)]]
    }()

    /// The field each shape runs on: a selection for the selection chains, a caret after the word otherwise.
    private func field(for steps: [ReplacementStep]) -> FakeTextField {
        if case .backspaceAndType = steps.first { return FakeTextField("hello akuo") }
        return FakeTextField("hello akuo world", selection: sel(6, 4))
    }

    @TextActor func testRefusedWriteGateWritesNothingOnEveryPlanShape() async {
        for steps in Self.writePlans {
            poster = RecordingPoster()
            let f = field(for: steps)
            let (text, selection) = (f.text, f.selection)
            let x = executor(f)
            _ = x.focusInfo(timeout: 0.25)
            var caps = ReplacementCapabilities()
            var asked = 0
            let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: "akuo", convert: convert,
                                           capabilities: &caps, mayWrite: { asked += 1; return false })
            XCTAssertEqual(out.result, .abandoned, "\(steps)")
            XCTAssertEqual(asked, 1, "\(steps)")
            XCTAssertTrue(out.attempts.isEmpty, "\(steps)")
            XCTAssertTrue(f.writes.isEmpty, "\(steps)")
            XCTAssertEqual(f.text, text, "\(steps)")
            XCTAssertEqual(f.selection, selection, "\(steps)")
            XCTAssertTrue(poster.events.isEmpty, "\(steps)")
            XCTAssertFalse(caps.isAXWriteBroken(for: app), "\(steps)")
            XCTAssertFalse(out.shouldBeep, "\(steps)")
        }
    }

    /// Every step fails untouched (AX no-op, poster refuses the first event, pasteboard not in the MVP), so the
    /// chain walks the whole shape: the gate is asked once, before the first step runs, and never again.
    @TextActor func testWriteGateIsAskedOnceBeforeTheFirstStepOnEveryPlanShape() async {
        for steps in Self.writePlans {
            poster = RecordingPoster()
            poster.failFrom = 0
            let f = field(for: steps)
            f.writeBehavior = .silentNoop
            let counting = CountingReplacer(executor(f))
            _ = counting.focusInfo(timeout: 0.25)
            var caps = ReplacementCapabilities()
            var asked = 0
            var performedWhenAsked: Int?
            let out = ReplacementChain.run(.steps(steps), on: counting, bundleID: app, old: "akuo", convert: convert,
                                           capabilities: &caps, mayWrite: {
                                               asked += 1
                                               performedWhenAsked = counting.performed.count
                                               return true
                                           })
            XCTAssertEqual(out.result, .exhausted, "\(steps)")
            XCTAssertEqual(asked, 1, "\(steps)")
            XCTAssertEqual(performedWhenAsked, 0, "the claim comes before the first step: \(steps)")
            XCTAssertEqual(counting.performed, steps, "\(steps)")
        }
    }

    @TextActor func testWriteGateIsNotAskedWhenNothingCanBeWrittenOnAnyPlanShape() async {
        for steps in Self.writePlans {
            for old in ["xyz", ""] {   // unconvertible text; no text at all
                let f = field(for: steps)
                let x = executor(f)
                _ = x.focusInfo(timeout: 0.25)
                var caps = ReplacementCapabilities()
                var asked = 0
                let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: old, convert: convert,
                                               capabilities: &caps, mayWrite: { asked += 1; return true })
                XCTAssertEqual(out.result, old.isEmpty ? .exhausted : .notConvertible, "\(steps)")
                XCTAssertEqual(asked, 0, "\(steps) old=\(old)")
                XCTAssertTrue(f.writes.isEmpty, "\(steps)")
            }
        }
        XCTAssertTrue(poster.events.isEmpty)
    }

    // MARK: - P2-49: nothing written when the field moved, changed, hung, or may be a password

    @TextActor func testFocusThatMovedBeforeAKeyStepPostsNothingOnEveryPlanShape() async {
        for steps in Self.writePlans {
            poster = RecordingPoster()
            let f = field(for: steps)
            f.writeBehavior = .silentNoop
            let provider = FakeFocusProvider(f)
            let x = ReplacementExecutor(focusProvider: provider, poster: poster)
            _ = x.focusInfo(timeout: 0.25)
            let other = FakeTextField("someone else's chat")
            provider.result = .success(other)   // the user clicked elsewhere after the double-Shift
            var caps = ReplacementCapabilities()
            let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: "akuo", convert: convert,
                                           capabilities: &caps)
            XCTAssertEqual(out.result, .exhausted, "\(steps)")
            XCTAssertTrue(out.shouldBeep, "\(steps)")
            XCTAssertTrue(poster.events.isEmpty, "\(steps)")
            XCTAssertTrue(other.writes.isEmpty, "\(steps)")
            XCTAssertEqual(other.text, "someone else's chat", "\(steps)")
        }
    }

    @TextActor func testSelectionThatChangedBeforeTypeOverPostsNothing() async {
        for changed in [sel(10, 0), sel(6, 3), sel(6, 5)] {
            for steps in Self.writePlans where steps.contains(.typeOverSelection) {
                poster = RecordingPoster()
                let f = field(for: steps)
                f.writeBehavior = .silentNoop
                let x = executor(f)
                let focus = x.focusInfo(timeout: 0.25)
                f.selection = changed   // e.g. the app dropped the selection: typing would insert the text twice
                var caps = ReplacementCapabilities()
                let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: focus?.selection,
                                               convert: convert, capabilities: &caps)
                XCTAssertFalse(out.succeeded, "\(steps) \(changed)")
                XCTAssertTrue(poster.events.isEmpty, "\(steps) \(changed)")
                XCTAssertEqual(f.text, "hello akuo world", "\(steps) \(changed)")
            }
        }
    }

    @TextActor func testSelectionThatChangedBehindAGarbageRangePostsNothing() async {
        // QA P2-49: AX reports an implausible range (R5 WebKit) while the selection really collapsed: the type-over
        // falls back to the selected text, which no longer matches, so nothing is typed (not "akuo" twice).
        for steps in Self.writePlans where steps.contains(.typeOverSelection) {
            poster = RecordingPoster()
            let f = field(for: steps)
            f.writeBehavior = .silentNoop
            let x = executor(f)
            let focus = x.focusInfo(timeout: 0.25)
            f.selection = sel(10, 0)
            f.reportedRange = sel(6, 4_294_967_292)
            var caps = ReplacementCapabilities()
            let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: focus?.selection,
                                           convert: convert, capabilities: &caps)
            XCTAssertFalse(out.succeeded, "\(steps)")
            XCTAssertTrue(poster.events.isEmpty, "\(steps)")
            XCTAssertEqual(f.text, "hello akuo world", "\(steps)")
        }
    }

    @TextActor func testHungAppCostsOneTimeoutAndPostsNothingOnEveryPlanShape() async {
        for steps in Self.writePlans {
            for behavior in [FakeTextField.WriteBehavior.timesOut, .writesThenTimesOut] {
                poster = RecordingPoster()
                let f = field(for: steps)
                f.writeBehavior = behavior
                let provider = FakeFocusProvider(f)
                let x = ReplacementExecutor(focusProvider: provider, poster: poster)
                _ = x.focusInfo(timeout: 0.25)
                // From here on the app is hung: the focused-element read times out too.
                provider.result = .failure(.timeout)
                var caps = ReplacementCapabilities()
                let out = ReplacementChain.run(.steps(steps), on: x, bundleID: app, old: "akuo", convert: convert,
                                               capabilities: &caps)
                XCTAssertFalse(out.succeeded, "\(steps)")
                XCTAssertTrue(out.shouldBeep, "\(steps)")
                XCTAssertTrue(poster.events.isEmpty, "\(steps)")
                XCTAssertEqual(f.callsAfterTimeout, 0, "nothing is asked of a hung app after its first timeout")
                XCTAssertLessThanOrEqual(provider.timeouts.count, 2, "focusInfo + at most one timed-out re-check")
                if steps.contains(.axWriteSelection(verify: true)) {
                    // A write that timed out may or may not have landed: unknown, so the chain halts.
                    XCTAssertEqual(out.result, .halted(after: .axWriteSelection(verify: true)), "\(steps)")
                }
            }
        }
    }

    @TextActor func testFailedSubroleReadIsRefusedAsSecure() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.role = "AXTextField"
        f.subroleResult = .failure(.failed)
        var caps = ReplacementCapabilities()
        let out = convertSelection(f, caps: &caps)
        XCTAssertEqual(out.result, .refused(.secureField))
        XCTAssertTrue(f.writes.isEmpty)
        XCTAssertFalse(f.reads.contains(.selectedText))
        XCTAssertTrue(poster.events.isEmpty)
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
    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        clock.advance(byNanos: stepNanos)
        return inner.readRunBeforeCaret(maxChars: maxChars, locate: locate)
    }
    var wordBeforeCaret: String? { inner.wordBeforeCaret }
    func endReplacement() { inner.endReplacement() }
}

/// Wraps an executor and records the steps the chain ran, to check the write gate comes before the first one.
@TextActor private final class CountingReplacer: TextReplacing {
    private let inner: ReplacementExecutor
    private(set) var performed: [ReplacementStep] = []

    init(_ inner: ReplacementExecutor) { self.inner = inner }

    func focusInfo(timeout: Double) -> FocusInfo? { inner.focusInfo(timeout: timeout) }
    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome {
        performed.append(step)
        return inner.perform(step, old: old, new: new)
    }
    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        performed.append(.axReadRunBeforeCaret(maxChars: maxChars))
        return inner.readRunBeforeCaret(maxChars: maxChars, locate: locate)
    }
    var wordBeforeCaret: String? { inner.wordBeforeCaret }
    func endReplacement() { inner.endReplacement() }
}
