// P2-18: ReplacementChain runs a plan over the executor: fall-through on a read-back mismatch, halting when the
// field state is unknown, verdict reporting to ReplacementCapabilities, the stale-buffer path, the key-posting
// gate, and the 400 ms budget.

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

    // MARK: - Gate, budget, cleanup

    @TextActor func testKeyPostingGateAbandonsSilently() async {
        let f = FakeTextField("hello akuo world", selection: sel(6, 4))
        f.writeBehavior = .silentNoop
        let x = executor(f)
        _ = x.focusInfo(timeout: 0.25)
        var caps = ReplacementCapabilities()
        var asked = 0
        let out = ReplacementChain.run(.steps([.axWriteSelection(verify: true), .typeOverSelection]), on: x,
                                       bundleID: app, old: "akuo", convert: convert, capabilities: &caps,
                                       mayPostKeys: { asked += 1; return false })
        XCTAssertEqual(out.result, .abandoned)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(poster.events.isEmpty)
        XCTAssertFalse(out.shouldBeep)
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
