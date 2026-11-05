// P2-12: Hold-back FIFO and deadlines with a fake clock (001 §7 B2), the B3 commit state machine,
// finishReplacement, aborts, and the P4 auto-fix trigger path.

import XCTest

final class HoldBackTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2

    private func makeProcessor(_ clock: FakeClock, autoFix: Bool = false, mode: TapMode = .active) -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.autoFixEnabled = autoFix
        config.mode = mode
        return KeyStreamProcessor(config: config, clock: clock)
    }

    /// Starts a convert and returns its generation.
    private func startConvert(_ p: inout KeyStreamProcessor) -> UInt64 {
        var gen: UInt64 = 0
        for e in F.doubleShift() {
            if case let .doubleShift(_, g)? = p.handle(e).1 { gen = g }
        }
        XCTAssertTrue(p.isReplacing)
        return gen
    }

    // MARK: - FIFO

    func testQueueCapIsClampedTo32() {
        XCTAssertEqual(HoldBackQueue(capacity: 100).capacity, 32)
        XCTAssertEqual(HoldBackQueue(capacity: 0).capacity, 1)
        var q = HoldBackQueue(capacity: 2)
        XCTAssertTrue(q.append(HeldEvent(event: F.key(a))))
        XCTAssertTrue(q.append(HeldEvent(event: F.key(s))))
        XCTAssertFalse(q.append(HeldEvent(event: F.key(d))))
        XCTAssertEqual(q.drain().map(\.event.keyCode), [a, s])
        XCTAssertTrue(q.isEmpty)
    }

    func testKeysAreHeldDuringConvertAndReplayedInOrder() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        feed(&p, [F.key(a), F.key(s)])
        let gen = startConvert(&p)
        let typed = [F.key(d), F.keyUp(d), F.key(a), F.keyUp(a)]
        for e in typed { XCTAssertEqual(p.handle(e).0, .hold) }
        XCTAssertEqual(p.buffer.strokeCount, 2, "held keys are buffered when they come back as replay")
        XCTAssertNil(p.pollFlush())

        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        let strokes = [Stroke(keyCode: a, layer: .plain), Stroke(keyCode: s, layer: .plain)]
        let held = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: strokes)
        XCTAssertEqual(held.map(\.event), typed)
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.inputSource, hebrew)
        XCTAssertEqual(Array(p.buffer.currentWord), strokes)
        // Replayed keys now pass and are buffered.
        XCTAssertEqual(p.handle(F.key(d, origin: .replay)).0, .pass)
        XCTAssertEqual(p.buffer.strokeCount, 3)
    }

    func testFlagsChangedPassesDuringReplacement() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        XCTAssertEqual(p.handle(F.flags(KeyCode.leftShift, F.left, at: 300)).0, .pass)
        XCTAssertEqual(p.heldCount, 0)
    }

    func testListenOnlyNeverHolds() {
        let clock = FakeClock()
        var p = makeProcessor(clock, mode: .listenOnly)
        let signals = F.doubleShift().compactMap { p.handle($0).1 }
        XCTAssertEqual(signals.count, 1)
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.handle(F.key(a)).0, .pass)
    }

    func testSecondDoubleShiftWhileReplacingIsIgnored() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let gen = startConvert(&p)
        let signals = F.doubleShift(at: 300).compactMap { p.handle($0).1 }
        XCTAssertEqual(signals, [])
        XCTAssertEqual(p.activeGeneration, gen)
    }

    // MARK: - Deadlines (B2)

    func testConvertDeadlineFlushesUnchangedAt400ms() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let gen = startConvert(&p)
        XCTAssertEqual(p.nextDeadlineNanos, 400 * F.ms)
        _ = p.handle(F.key(a))
        clock.advance(byMilliseconds: 399)
        XCTAssertNil(p.pollFlush())
        clock.advance(byMilliseconds: 1)
        XCTAssertEqual(p.pollFlush()?.map(\.event.keyCode), [a])
        XCTAssertFalse(p.isReplacing)
        // The late worker result is ignored (B2).
        XCTAssertEqual(p.finishReplacement(gen: gen, newRendering: InputSourceID("x"), bufferAfter: []), [])
        XCTAssertNil(p.inputSource)
        XCTAssertEqual(p.handle(F.key(s)).0, .pass)
    }

    func testStaleGenerationFinishIsIgnoredWhileANewOneRuns() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let first = startConvert(&p)
        clock.advance(byMilliseconds: 400)
        _ = p.pollFlush()
        clock.advance(byMilliseconds: 1000)
        var second: UInt64 = 0
        for e in F.doubleShift(at: 2000) {
            if case let .doubleShift(_, g)? = p.handle(e).1 { second = g }
        }
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.finishReplacement(gen: first, newRendering: nil, bufferAfter: nil), [])
        XCTAssertTrue(p.isReplacing)
        XCTAssertEqual(p.finishReplacement(gen: second, newRendering: nil, bufferAfter: nil).count, 1)
    }

    func testPostingWorkerGetsTheHardCapNotTheDeadline() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        _ = p.handle(F.key(a))
        clock.advance(byMilliseconds: 400)
        XCTAssertNil(p.pollFlush(postingStarted: true), "the worker won the commit: wait")
        XCTAssertEqual(p.nextDeadlineNanos, 1400 * F.ms)
        clock.advance(byMilliseconds: 999)
        XCTAssertNil(p.pollFlush(postingStarted: true))
        clock.advance(byMilliseconds: 1)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 1, "1 s hard cap, then a forced flush (B3)")
    }

    // MARK: - Aborts

    func testOverflowFlushesAtThe32ndEventAndNeverHoldsMore() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        for i in 0..<31 {
            XCTAssertEqual(p.handle(F.key(UInt16(i % 20))).0, .hold)
            XCTAssertNil(p.pollFlush())
        }
        XCTAssertEqual(p.handle(F.key(a)).0, .hold)
        XCTAssertEqual(p.heldCount, 32)
        let flushed = p.pollFlush()
        XCTAssertEqual(flushed?.count, 32)
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.handle(F.key(a)).0, .pass)
    }

    func testShortcutDuringReplacementIsHeldThenFlushed() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(F.key(s, command: true)).0, .hold)
        XCTAssertEqual(p.pollFlush()?.map(\.event.keyCode), [a, s])
    }

    func testClickDuringReplacementPassesAndFlushes() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        feed(&p, [F.key(d)])
        _ = startConvert(&p)
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(F.pointer()).0, .pass)
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertEqual(p.pollFlush()?.count, 1)
    }

    func testResetDuringReplacementFlushes() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let gen = startConvert(&p)
        _ = p.handle(F.key(a))
        p.reset(.contextChange)
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.pollFlush()?.count, 1)
        XCTAssertEqual(p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil), [])
    }

    func testKeysAfterAnAbortStayInOrderUntilFlushed() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        _ = p.handle(F.key(a))
        p.reset(.secureInputOn)
        XCTAssertEqual(p.handle(F.key(s)).0, .hold, "the flush hasn't gone out yet, so keep order")
        XCTAssertEqual(p.pollFlush()?.map(\.event.keyCode), [a, s])
        XCTAssertNil(p.pollFlush())
    }

    // MARK: - Auto-fix trigger (P4 path)

    func testAutoFixHoldsTheTriggerWith150msDeadline() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        feed(&p, [F.key(a), F.key(s)])
        let (verdict, signal) = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(verdict, .hold)
        guard case let .wordEnded(snap, gen)? = signal else { return XCTFail("no wordEnded") }
        XCTAssertEqual(snap.strokes.count, 2)
        XCTAssertEqual(gen, 1)
        XCTAssertEqual(p.nextDeadlineNanos, 150 * F.ms)
        _ = p.handle(F.key(d))
        clock.advance(byMilliseconds: 150)
        XCTAssertEqual(p.pollFlush()?.map(\.event.keyCode), [KeyCode.space, d], "Space + FIFO, unchanged")
    }

    func testAutoFixKeepReplaysTheTrigger() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        feed(&p, [F.key(a)])
        _ = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(p.finishReplacement(gen: 1, newRendering: nil, bufferAfter: nil).map(\.event.keyCode),
                       [KeyCode.space])
    }

    func testAutoFixFixDropsTheTriggerAndEndsTheWord() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        feed(&p, [F.key(a)])
        _ = p.handle(F.key(KeyCode.space))
        _ = p.handle(F.key(d))
        let held = p.finishReplacement(gen: 1, newRendering: InputSourceID("he"),
                                       bufferAfter: [Stroke(keyCode: a, layer: .plain)])
        XCTAssertEqual(held.map(\.event.keyCode), [d])
        XCTAssertTrue(p.buffer.currentWord.isEmpty)
        XCTAssertEqual(p.buffer.wordCount, 1)
    }

    func testAutoFixIgnoresEmptyWordsReplayAndAutoRepeat() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).0, .pass)
        feed(&p, [F.key(a)])
        XCTAssertEqual(p.handle(F.key(KeyCode.space, origin: .replay)).0, .pass)
        feed(&p, [F.key(a)])
        XCTAssertEqual(p.handle(F.key(KeyCode.space, autoRepeat: true)).0, .pass)
    }

    func testAutoFixOffByDefault() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        feed(&p, [F.key(a)])
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).0, .pass)
    }

    // MARK: - Commit (B3)

    func testCommitWorkerWins() {
        var c = HoldBackCommit()
        c.arm(gen: 1)
        XCTAssertTrue(c.claimPosting(gen: 1))
        XCTAssertFalse(c.claimFlush(gen: 1), "deadline must wait for the posting worker")
        XCTAssertFalse(c.claimPosting(gen: 1), "only one post")
        c.finish(gen: 1)
        XCTAssertEqual(c.state, .idle)
    }

    func testCommitDeadlineWins() {
        var c = HoldBackCommit()
        c.arm(gen: 1)
        XCTAssertTrue(c.claimFlush(gen: 1))
        XCTAssertEqual(c.state, .flushed(gen: 1))
        XCTAssertFalse(c.claimPosting(gen: 1), "the worker abandons the replacement")
        XCTAssertTrue(c.claimFlush(gen: 1))
    }

    func testCommitIgnoresOtherGenerations() {
        var c = HoldBackCommit()
        c.arm(gen: 2)
        XCTAssertFalse(c.claimPosting(gen: 1))
        XCTAssertTrue(c.claimFlush(gen: 1))
        c.finish(gen: 1)
        XCTAssertEqual(c.state, .pending(gen: 2))
        var fresh = HoldBackCommit()
        XCTAssertFalse(fresh.claimPosting(gen: 0), "nothing armed: nothing to post")
    }

    @discardableResult
    private func feed(_ p: inout KeyStreamProcessor, _ events: [KeyEvent]) -> [KeySignal] {
        events.compactMap { p.handle($0).1 }
    }
}
