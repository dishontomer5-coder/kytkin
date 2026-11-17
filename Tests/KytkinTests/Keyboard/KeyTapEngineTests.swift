// P2-17: KeyWatcher's tap-thread plumbing against a fake backend (001 §2.2 adapter contract, §7 B2–B4, §12 K1).
// Nothing here installs a tap or posts an event: CGEvents are built in memory and handed to the engine's handler.

import CoreGraphics
import XCTest

final class KeyTapEngineTests: XCTestCase {
    private typealias T = TapEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")

    private var clock: FakeClock!
    private var backend: FakeKeyTapBackend!
    private var commit: HoldBackCommitLock!
    private var engine: KeyTapEngine!
    private var signals: [KeySignal] = []
    private var statuses: [KeyWatcherStatus] = []
    /// The commit state at the moment each signal was sent.
    private var commitAtSignal: [HoldBackCommit.State] = []

    override func setUp() {
        super.setUp()
        signals = []
        statuses = []
        commitAtSignal = []
    }

    @discardableResult
    private func makeEngine(mode: TapMode = .active, autoFix: Bool = false) -> TapMode {
        clock = FakeClock(nowNanos: 10_000 * T.ms)
        backend = FakeKeyTapBackend()
        commit = HoldBackCommitLock()
        var config = KeyProcessorConfig()
        config.autoFixEnabled = autoFix
        let commit = commit!
        engine = KeyTapEngine(
            processor: KeyStreamProcessor(config: config, clock: clock), commit: commit, backend: backend,
            clock: clock, timestamps: EventTimestampNormalizer(numer: 1, denom: 1), machNow: { 0 },
            sendSignal: { [unowned self] in
                signals.append($0)
                commitAtSignal.append(commit.state)
            },
            sendStatus: { [unowned self] in statuses.append($0) })
        return engine.applyMode(mode, userInitiated: true)
    }

    @discardableResult
    private func deliver(_ e: CGEvent, _ type: CGEventType? = nil) -> Bool? {
        backend.deliver(type ?? e.type, e)
    }

    /// Runs a double-Shift through the handler and returns its generation.
    private func doubleShift() -> UInt64 {
        let t = clock.nowNanos / T.ms
        for (type, e) in T.doubleShift(at: t) { XCTAssertEqual(deliver(e, type), true, "Shift taps always pass") }
        guard case let .doubleShift(_, gen)? = signals.last else {
            XCTFail("no double-Shift signal")
            return 0
        }
        return gen
    }

    private var postedCodes: [Int64] { backend.posted.map(\.keyCode) }

    // MARK: - Marker first

    func testOurOwnEventsPassAndNeverReachTheBuffer() {
        makeEngine()
        XCTAssertEqual(deliver(T.key(a, marker: EventOrigin.oursMarker)), true)
        XCTAssertTrue(engine.processor.buffer.isEmpty, "our replacement text must never be buffered (R4 §5)")
    }

    func testReplayedEventsAreBufferedAsUserTyping() {
        makeEngine()
        XCTAssertEqual(deliver(T.key(a, marker: EventOrigin.replayMarker)), true)
        XCTAssertFalse(engine.processor.buffer.isEmpty)
    }

    func testUserKeysPassAndAreBuffered() {
        makeEngine()
        XCTAssertEqual(deliver(T.key(a)), true)
        XCTAssertEqual(deliver(T.key(a, down: false)), true)
        XCTAssertEqual(engine.processor.buffer.snapshot(renderedIn: nil).strokes.count, 1)
        XCTAssertEqual(engine.heldCGEventCount, 0)
    }

    func testEventsTheProcessorDoesNotWantPassUntouched() {
        makeEngine()
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
                           mouseButton: .left)!
        XCTAssertEqual(deliver(move), true)
    }

    // MARK: - Arm before signal, hold, deadline flush (contract steps 1–2)

    func testDoubleShiftArmsTheCommitBeforeTheSignalIsSent() {
        makeEngine()
        let gen = doubleShift()
        XCTAssertEqual(commitAtSignal.last, .pending(gen: gen), "a worker must find the commit armed")
        XCTAssertEqual(backend.armedDeadline, clock.nowNanos + 400 * T.ms, "convert deadline timer")
    }

    func testKeysDuringAReplacementAreSwallowedAndReplayedInOrderAtTheDeadline() {
        makeEngine()
        let gen = doubleShift()
        XCTAssertEqual(deliver(T.key(a)), false)
        XCTAssertEqual(deliver(T.key(a, down: false)), false)
        XCTAssertEqual(deliver(T.key(s)), false)
        XCTAssertEqual(engine.heldCGEventCount, 3)
        XCTAssertTrue(backend.posted.isEmpty)

        clock.advance(byMilliseconds: 400)
        backend.fireDeadline()
        XCTAssertEqual(postedCodes, [Int64(a), Int64(a), Int64(s)])
        XCTAssertEqual(backend.posted.map(\.keyDown), [true, false, true])
        XCTAssertTrue(backend.posted.allSatisfy { $0.marker == EventOrigin.replayMarker }, "replays carry the replay marker")
        XCTAssertEqual(commit.state, .idle)
        XCTAssertEqual(engine.heldCGEventCount, 0)
        XCTAssertNil(backend.armedDeadline)
        XCTAssertFalse(commit.claimPosting(gen: gen), "the worker came too late: it must abandon")
    }

    func testADeadlineTimerThatFiresEarlyIsReArmed() {
        makeEngine()
        _ = doubleShift()
        let due = backend.armedDeadline
        clock.advance(byMilliseconds: 399)
        backend.fireDeadline()
        XCTAssertEqual(backend.armedDeadline, due, "re-armed for the same time")
        XCTAssertTrue(backend.posted.isEmpty)
    }

    // MARK: - The worker wins the commit (B3, K1)

    func testAPostingWorkerIsWaitedForAndItsFinishReplaysExactlyOnce() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))

        clock.advance(byMilliseconds: 400)
        backend.fireDeadline()
        XCTAssertTrue(backend.posted.isEmpty, "never interleave held keys with the worker's posts")
        XCTAssertEqual(backend.armedDeadline, clock.nowNanos + 1_000 * T.ms, "hard cap armed")

        // K1: at the moment of the replay, the commit still belongs to the worker; finish comes after.
        var statesAtPost: [HoldBackCommit.State] = []
        let commit = commit!
        backend.onPost = { _ in statesAtPost.append(commit.state) }
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a)])
        XCTAssertEqual(statesAtPost, [.posting(gen: gen)], "commit.finish runs after the replay, never before")
        XCTAssertEqual(commit.state, .idle)
        XCTAssertNil(backend.armedDeadline)

        clock.advance(byMilliseconds: 2_000)
        backend.fireDeadline()
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a)], "no second replay")
    }

    func testAWorkerStuckPastTheHardCapIsFlushedAnyway() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        clock.advance(byMilliseconds: 400)
        backend.fireDeadline()
        clock.advance(byMilliseconds: 1_000)
        backend.fireDeadline()
        XCTAssertEqual(postedCodes, [Int64(a)], "the keyboard never stays held past the hard cap")
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a)], "its late finish replays nothing")
    }

    /// QA (P2-17): once the hard cap is armed, the next held key must not flush under the posting worker.
    func testKeysTypedDuringTheHardCapWaitStayHeldBehindThePostingWorker() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        clock.advance(byMilliseconds: 400)
        backend.fireDeadline()
        clock.advance(byMilliseconds: 10)
        XCTAssertEqual(deliver(T.key(s)), false, "still held")
        XCTAssertTrue(backend.posted.isEmpty, "never interleave held keys with the worker's posts")
        XCTAssertEqual(engine.heldCGEventCount, 2)
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a), Int64(s)])
    }

    /// QA (P2-17): same after an abort (click) while the worker posts.
    func testKeysTypedAfterAnAbortWhileTheWorkerPostsStayHeld() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        _ = deliver(T.mouseDown())
        XCTAssertEqual(deliver(T.key(s)), false)
        engine.runFlushStep() // as after any hop onto the tap thread
        XCTAssertTrue(backend.posted.isEmpty)
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a), Int64(s)])
    }

    func testAStaleFinishLeavesANewerReplacementAlone() {
        makeEngine()
        let gen1 = doubleShift()
        clock.advance(byMilliseconds: 400)
        backend.fireDeadline() // gen1 flushed (nothing held)
        clock.advance(byMilliseconds: 100)
        let gen2 = doubleShift()
        _ = deliver(T.key(d))
        engine.finishReplacement(gen: gen1, newRendering: hebrew, bufferAfter: nil)
        XCTAssertTrue(backend.posted.isEmpty)
        XCTAssertEqual(commit.state, .pending(gen: gen2))
        XCTAssertEqual(engine.heldCGEventCount, 1, "gen2's held key is kept for its own replay")
        engine.finishReplacement(gen: gen2, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(d)])
    }

    // MARK: - Aborts

    func testAClickDuringAReplacementFlushesHeldKeysAtOnce() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertEqual(deliver(T.mouseDown()), true, "the click itself passes")
        XCTAssertEqual(postedCodes, [Int64(a)])
        XCTAssertEqual(commit.state, .idle)
    }

    func testAnAbortWaitsForAWorkerThatIsAlreadyPosting() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        _ = deliver(T.mouseDown())
        XCTAssertTrue(backend.posted.isEmpty)
        XCTAssertEqual(backend.armedDeadline, clock.nowNanos + 1_000 * T.ms)
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a)])
    }

    func testAShortcutDuringAReplacementIsReplayedAfterTheHeldKeys() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertEqual(deliver(T.key(8, flags: CGEventFlags.maskCommand.rawValue)), false)
        XCTAssertEqual(postedCodes, [Int64(a), 8])
    }

    func testAMainThreadResetFlushesThroughPerform() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        engine.perform(.reset(.contextChange))
        XCTAssertEqual(postedCodes, [Int64(a)])
    }

    // MARK: - Auto-fix (P4 path, already plumbed)

    func testAFixedAutoFixReplaysEverythingButItsTrigger() {
        makeEngine(autoFix: true)
        _ = deliver(T.key(a))
        _ = deliver(T.key(a, down: false))
        XCTAssertEqual(deliver(T.key(KeyCode.space)), false, "the trigger is held")
        guard case let .wordEnded(_, gen)? = signals.last else { return XCTFail("no wordEnded") }
        XCTAssertEqual(commitAtSignal.last, .pending(gen: gen))
        _ = deliver(T.key(s))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: [Stroke(keyCode: a, layer: .plain)])
        XCTAssertEqual(postedCodes, [Int64(s)], "the worker typed its own Space; the held one is dropped")
        XCTAssertEqual(engine.heldCGEventCount, 0)
    }

    // MARK: - Listen-only

    func testListenOnlyDoubleShiftSignalsButNeverArmsOrHolds() {
        XCTAssertEqual(makeEngine(mode: .listenOnly), .listenOnly)
        XCTAssertEqual(backend.installs, [.listenOnly])
        _ = doubleShift()
        XCTAssertEqual(commit.state, .idle, "main only toggles the language (§3c)")
        XCTAssertEqual(deliver(T.key(a)), true)
        XCTAssertEqual(engine.heldCGEventCount, 0)
    }

    // MARK: - Modes and permissions

    func testNoPermissionMeansNoInstallAndOff() {
        clock = FakeClock()
        backend = FakeKeyTapBackend()
        backend.granted = []
        engine = KeyTapEngine(processor: KeyStreamProcessor(clock: clock), commit: HoldBackCommitLock(),
                              backend: backend, clock: clock, sendSignal: { _ in }, sendStatus: { _ in })
        XCTAssertEqual(engine.applyMode(.active, userInitiated: true), .off)
        XCTAssertEqual(engine.applyMode(.listenOnly, userInitiated: true), .off)
        XCTAssertTrue(backend.installs.isEmpty, "never call tapCreate without the silent check: it could prompt")
    }

    func testAFailedTapCreateIsOff() {
        clock = FakeClock()
        backend = FakeKeyTapBackend()
        backend.installSucceeds = false
        engine = KeyTapEngine(processor: KeyStreamProcessor(clock: clock), commit: HoldBackCommitLock(),
                              backend: backend, clock: clock, sendSignal: { _ in }, sendStatus: { _ in })
        XCTAssertEqual(engine.applyMode(.active, userInitiated: true), .off)
        XCTAssertEqual(engine.mode, .off)
    }

    func testStartPublishesTheAchievedMode() {
        makeEngine()
        XCTAssertEqual(statuses.last?.health.mode, .active)
        XCTAssertEqual(engine.processor.mode, .active)
    }

    func testStoppingFlushesHeldKeysAndRemovesTheTap() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertEqual(engine.applyMode(.off, userInitiated: true), .off)
        XCTAssertEqual(postedCodes, [Int64(a)], "a stop never eats a key")
        XCTAssertNil(backend.handler)
        XCTAssertEqual(statuses.last?.health.mode, .off)
    }

    /// P2-27 (quit during a convert): the worker on @TextActor hasn't posted yet when the app quits. The shutdown
    /// replays the held key and wins the B3 commit, so the worker's `claimPosting` fails and it writes nothing after
    /// the tap is gone (no converted text landing after the keys typed behind it).
    func testQuitBeforeTheWorkerPostsFlushesAndTheWorkerCanNoLongerWrite() {
        makeEngine()
        let gen = doubleShift()
        XCTAssertEqual(commit.state, .pending(gen: gen))
        _ = deliver(T.key(a))
        engine.shutdown()
        XCTAssertEqual(postedCodes, [Int64(a)], "a quit never eats a key")
        XCTAssertNil(backend.handler)
        XCTAssertFalse(commit.claimPosting(gen: gen), "the worker must not post after the quit flushed")
    }

    /// P2-27: the worker is already posting when the app quits. The tap is not active any more, so the held key is
    /// replayed at once rather than kept waiting for a finish that may never come (the accepted 001 §12.2 limit:
    /// it can land before the rest of the converted text). Nothing is lost and the tap is removed.
    func testQuitWhileTheWorkerPostsStillReplaysTheHeldKey() {
        makeEngine()
        let gen = doubleShift()
        XCTAssertTrue(commit.claimPosting(gen: gen))
        _ = deliver(T.key(a))
        engine.shutdown()
        XCTAssertEqual(postedCodes, [Int64(a)])
        XCTAssertNil(backend.handler)
        XCTAssertTrue(backend.timersDetached)
    }

    /// QA (P2-17): stop flushes, removes the tap, and invalidates the timers (their handlers hold the engine unowned).
    func testShutdownFlushesThenDetachesTheTimers() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        engine.shutdown()
        XCTAssertEqual(postedCodes, [Int64(a)])
        XCTAssertNil(backend.handler)
        XCTAssertTrue(backend.timersDetached)
        backend.fireDeadline() // a detached timer can't call back
        backend.firePoll()
        XCTAssertEqual(postedCodes, [Int64(a)])
    }

    func testSwitchingToListenOnlyMidHoldFlushes() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertEqual(engine.applyMode(.listenOnly, userInitiated: true), .listenOnly)
        XCTAssertEqual(postedCodes, [Int64(a)])
        XCTAssertEqual(backend.installs, [.active, .listenOnly])
    }

    /// P2-47: held keys are re-posted while the old tap is still installed, so nothing typed during the switch (into
    /// no tap, or the new one) can overtake them.
    func testAModeSwitchReplaysHeldKeysBeforeTheOldTapIsRemoved() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        _ = deliver(T.key(s))
        backend.clearCalls()
        XCTAssertEqual(engine.applyMode(.listenOnly, userInitiated: true), .listenOnly)
        XCTAssertEqual(backend.calls, ["post \(a)", "post \(s)", "uninstall", "install listenOnly"])
        XCTAssertEqual(engine.heldCGEventCount, 0)
    }

    /// P2-47: same with a worker that already won the commit: there's no tap to hold keys behind it during the gap.
    func testAModeSwitchUnderAPostingWorkerStillReplaysFirst() {
        makeEngine()
        let gen = doubleShift()
        _ = deliver(T.key(a))
        XCTAssertTrue(commit.claimPosting(gen: gen))
        backend.clearCalls()
        engine.applyMode(.listenOnly, userInitiated: true)
        XCTAssertEqual(backend.calls, ["post \(a)", "uninstall", "install listenOnly"])
        engine.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil)
        XCTAssertEqual(postedCodes, [Int64(a)], "the stale finish replays nothing")
    }

    /// P2-47: re-installing the same mode (the tap was found disabled), a stop, and the watchdog's downgrade too.
    func testEveryTapReplacementReplaysHeldKeysFirst() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        backend.enabled = false
        backend.clearCalls()
        engine.applyMode(.active, userInitiated: true)
        XCTAssertEqual(backend.calls, ["post \(a)", "uninstall", "install active"])

        clock.advance(byMilliseconds: 500)
        _ = doubleShift()
        _ = deliver(T.key(s))
        backend.clearCalls()
        engine.shutdown()
        XCTAssertEqual(backend.calls, ["post \(s)", "uninstall"])

        makeEngine()
        for _ in 0..<2 { notifyDisabled() }
        _ = doubleShift()
        _ = deliver(T.key(d))
        notifyDisabled() // the 3rd: downgrade, after the callback
        backend.runSoonBlocks()
        XCTAssertEqual(postedCodes, [Int64(d)])
        XCTAssertEqual(Array(backend.calls.suffix(3)), ["post \(d)", "uninstall", "install listenOnly"])
    }

    // MARK: - Watchdog (B4)

    private func notifyDisabled() {
        _ = deliver(T.key(0), .tapDisabledByTimeout)
    }

    func testATimeoutReEnablesTheTapAndForgetsTheWord() {
        makeEngine()
        _ = deliver(T.key(a))
        notifyDisabled()
        XCTAssertEqual(backend.reEnableCount, 1)
        XCTAssertEqual(statuses.last?.health.reEnableCount, 1)
        XCTAssertTrue(engine.processor.buffer.isEmpty, "events were missed: the buffer can't be trusted")
        XCTAssertEqual(signals.last, .bufferInvalidated)
    }

    func testRepeatedTimeoutsDowngradeToListenOnlyThenTurnOff() {
        makeEngine()
        for _ in 0..<3 { notifyDisabled(); clock.advance(byMilliseconds: 100) }
        XCTAssertEqual(backend.reEnableCount, 2)
        XCTAssertEqual(backend.installs, [.active], "never replace a tap from inside its own callback")
        XCTAssertEqual(backend.soon.count, 1)
        backend.runSoonBlocks()
        XCTAssertEqual(backend.installs, [.active, .listenOnly])
        XCTAssertEqual(statuses.last?.health.mode, .listenOnly)
        XCTAssertEqual(statuses.last?.degradedByWatchdog, true)

        for _ in 0..<3 { notifyDisabled(); clock.advance(byMilliseconds: 100) }
        backend.runSoonBlocks()
        XCTAssertEqual(engine.mode, .off)
        XCTAssertNil(backend.handler)
        XCTAssertEqual(backend.installs, [.active, .listenOnly])
    }

    func testDowngradeWithoutInputMonitoringTurnsTheTapOff() {
        makeEngine()
        backend.granted = [.active]
        for _ in 0..<3 { notifyDisabled() }
        backend.runSoonBlocks()
        XCTAssertEqual(engine.mode, .off, "a listen-only tap without Input Monitoring could prompt")
        XCTAssertEqual(backend.installs, [.active])
    }

    func testThePollForgetsTheBufferAfterThreeIdleMinutes() {
        // P3-34 (3)
        makeEngine()
        _ = deliver(T.key(a))
        backend.firePoll()
        XCTAssertFalse(engine.processor.buffer.isEmpty)
        clock.advance(byNanos: KeyStreamProcessor.idleExpiryNanos)
        backend.firePoll()
        XCTAssertTrue(engine.processor.buffer.isEmpty)
        XCTAssertEqual(signals.last, .bufferInvalidated)
    }

    func testTheWatchdogPollReEnablesASilentlyDisabledTap() {
        makeEngine()
        backend.enabled = false
        backend.firePoll()
        XCTAssertEqual(backend.reEnableCount, 0, "checked every 2nd poll (2 s)")
        backend.firePoll()
        XCTAssertEqual(backend.reEnableCount, 1)
    }

    /// P2-47 QA: the watchdog's downgrade runs after the callback, so a user `applyMode` (main's stop, a start, or the
    /// undo of a timed-out start) can be queued ahead of it. The stale downgrade must not install a tap behind it.
    func testAPendingWatchdogDowngradeNeverOverridesAUserModeChange() {
        makeEngine()
        for _ in 0..<3 { notifyDisabled() }
        XCTAssertEqual(backend.soon.count, 1)
        engine.applyMode(.off, userInitiated: true) // e.g. the undo of a timed-out start
        backend.runSoonBlocks()
        XCTAssertEqual(engine.mode, .off)
        XCTAssertNil(backend.handler, "no listen-only tap after main was told off")
        XCTAssertEqual(backend.installs, [.active])

        makeEngine()
        for _ in 0..<3 { notifyDisabled() }
        engine.shutdown()
        backend.runSoonBlocks()
        XCTAssertNil(backend.handler, "nothing installed after a stop")
        XCTAssertEqual(backend.installs, [.active])

        makeEngine()
        for _ in 0..<3 { notifyDisabled() }
        backend.enabled = false
        XCTAssertEqual(engine.applyMode(.active, userInitiated: true), .active) // the user re-starts active
        backend.runSoonBlocks()
        XCTAssertEqual(engine.mode, .active, "the user's later start wins over the older downgrade")
        XCTAssertEqual(backend.installs, [.active, .active])
    }

    func testAUserStartClearsTheWatchdogHistory() {
        makeEngine()
        notifyDisabled()
        notifyDisabled()
        engine.applyMode(.active, userInitiated: true)
        XCTAssertEqual(backend.installs, [.active], "same mode, tap enabled: nothing to reinstall")
        notifyDisabled()
        XCTAssertTrue(backend.soon.isEmpty, "the count started over")
    }

    // MARK: - Secure Input

    func testSecureInputResetsTheBufferAndIsReported() {
        makeEngine()
        _ = deliver(T.key(a))
        backend.secureInput = true
        backend.firePoll()
        XCTAssertEqual(statuses.last?.secureInputOn, true)
        XCTAssertTrue(engine.processor.buffer.isEmpty)
        XCTAssertEqual(signals.last, .bufferInvalidated)
        backend.secureInput = false
        engine.checkSecureInput(publishing: true)
        XCTAssertEqual(statuses.last?.secureInputOn, false)
    }

    func testSecureInputAbortsAReplacementAndFlushes() {
        makeEngine()
        _ = doubleShift()
        _ = deliver(T.key(a))
        backend.secureInput = true
        backend.firePoll()
        XCTAssertEqual(postedCodes, [Int64(a)])
    }

    func testNoPollingWhileOff() {
        makeEngine(mode: .off)
        backend.secureInput = true
        backend.firePoll()
        XCTAssertNotEqual(statuses.last?.secureInputOn, true)
    }

    // MARK: - B1 smoke

    /// Debug build: 20k translated events through the full callback path well under a second.
    func testCallbackPathStaysCheap() {
        makeEngine()
        let down = T.key(a), up = T.key(a, down: false), space = T.key(KeyCode.space)
        let start = Date()
        for i in 0..<10_000 {
            _ = deliver(i % 6 == 5 ? space : down, .keyDown)
            _ = deliver(up, .keyUp)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}
