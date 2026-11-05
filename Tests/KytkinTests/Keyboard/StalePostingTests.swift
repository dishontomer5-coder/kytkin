// P2-35: a generation force-flushed while its worker was posting blocks new replacements until its (stale)
// finish arrives or another postingHardCapNanos passes (001 §12 K4). Two workers posting at once would interleave.

import XCTest

final class StalePostingTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2

    private func makeProcessor(_ clock: FakeClock, autoFix: Bool = false) -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.autoFixEnabled = autoFix
        return KeyStreamProcessor(config: config, clock: clock)
    }

    /// Feeds a double-Shift at `t` ms and returns the signal it produced, if any.
    private func doubleShift(_ p: inout KeyStreamProcessor, at t: UInt64) -> KeySignal? {
        var signal: KeySignal?
        for e in F.doubleShift(at: t) {
            let (verdict, sig) = p.handle(e)
            XCTAssertEqual(verdict, .pass)
            if let sig { signal = sig }
        }
        return signal
    }

    /// Starts a convert at t = 0, lets the worker win the commit, and forces the flush at the hard cap.
    /// Returns the stale generation. The clock ends at 1400 ms.
    private func forceFlushAtHardCap(_ p: inout KeyStreamProcessor, _ clock: FakeClock) -> UInt64 {
        guard case let .doubleShift(_, gen)? = doubleShift(&p, at: 0) else {
            XCTFail("no convert")
            return 0
        }
        XCTAssertEqual(p.handle(F.key(a)).0, .hold)
        clock.advance(byMilliseconds: 400)
        XCTAssertNil(p.pollFlush(postingStarted: true))
        clock.advance(byMilliseconds: 1000)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.map(\.event.keyCode), [a])
        XCTAssertFalse(p.isReplacing)
        return gen
    }

    // MARK: - Refusal

    func testDoubleShiftIsRefusedWhileTheStaleWorkerMayPost() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = forceFlushAtHardCap(&p, clock)
        XCTAssertNil(doubleShift(&p, at: 2000), "no signal: main must not start a second worker")
        XCTAssertFalse(p.isReplacing)
        XCTAssertNil(p.activeGeneration)
        XCTAssertEqual(p.handle(F.key(s)).0, .pass, "no hold either")
        XCTAssertEqual(p.heldCount, 0)
    }

    func testAutoFixIsRefusedWhileTheStaleWorkerMayPost() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        _ = p.handle(F.key(d))
        _ = forceFlushAtHardCap(&p, clock)
        XCTAssertEqual(p.handle(F.key(s)).0, .pass)
        let (verdict, signal) = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(verdict, .pass, "the trigger passes, never held")
        if case .wordEnded? = signal { XCTFail("no auto-fix may start") }
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.heldCount, 0)
    }

    func testResetDoesNotClearTheRefusal() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = forceFlushAtHardCap(&p, clock)
        p.reset(.contextChange)
        p.setMode(.listenOnly)
        p.setMode(.active)
        XCTAssertNil(doubleShift(&p, at: 2000), "the worker is still running whatever we reset")
    }

    /// An abort (here: the FIFO filled) that flushes under a posting worker is remembered too.
    func testFlushForcedByAFullQueueWhilePostingIsRemembered() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        guard case let .doubleShift(_, gen)? = doubleShift(&p, at: 0) else { return XCTFail("no convert") }
        for _ in 0..<32 { XCTAssertEqual(p.handle(F.key(d)).0, .hold) }
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 32)
        XCTAssertNil(doubleShift(&p, at: 1000))
        XCTAssertEqual(p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil), [])
        XCTAssertNotNil(doubleShift(&p, at: 2000))
    }

    /// A mode change (listen-only can't hold) flushes under a posting worker at once: remembered, and listen-only
    /// double-Shift (which only toggles the language) is refused too.
    func testFlushForcedByAModeChangeWhilePostingIsRemembered() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        guard case .doubleShift? = doubleShift(&p, at: 0) else { return XCTFail("no convert") }
        p.setMode(.listenOnly)
        XCTAssertNotNil(p.pollFlush(postingStarted: true))
        XCTAssertNil(doubleShift(&p, at: 1000))
    }

    /// Nothing was posting, so nothing is stale: the next replacement may start at once.
    func testPlainDeadlineFlushDoesNotRefuse() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        guard case .doubleShift? = doubleShift(&p, at: 0) else { return XCTFail("no convert") }
        clock.advance(byMilliseconds: 400)
        XCTAssertNotNil(p.pollFlush())
        XCTAssertNotNil(doubleShift(&p, at: 1000))
        XCTAssertTrue(p.isReplacing)
    }

    // MARK: - Clearing

    func testRefusalClearsOnTheStaleFinish() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let stale = forceFlushAtHardCap(&p, clock)
        XCTAssertNil(doubleShift(&p, at: 2000))
        XCTAssertEqual(p.finishReplacement(gen: stale, newRendering: InputSourceID("x"), bufferAfter: []), [],
                       "still a stale finish: nothing to replay, nothing applied")
        XCTAssertNil(p.inputSource)
        guard case let .doubleShift(_, gen)? = doubleShift(&p, at: 3000) else { return XCTFail("not cleared") }
        XCTAssertGreaterThan(gen, stale)
        XCTAssertTrue(p.isReplacing)
        XCTAssertEqual(p.handle(F.key(s)).0, .hold)
    }

    func testAFinishForAnotherGenerationDoesNotClearTheRefusal() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let stale = forceFlushAtHardCap(&p, clock)
        _ = p.finishReplacement(gen: stale &+ 1, newRendering: nil, bufferAfter: nil)
        XCTAssertNil(doubleShift(&p, at: 2000))
    }

    func testRefusalClearsAtTheHardCap() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        _ = forceFlushAtHardCap(&p, clock) // flushed at 1400 ms → refused until 2400 ms
        clock.advance(byMilliseconds: 999)
        XCTAssertNil(doubleShift(&p, at: 2000))
        _ = p.handle(F.key(d))
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).0, .pass)
        clock.advance(byMilliseconds: 1)
        guard case .doubleShift? = doubleShift(&p, at: 3000) else { return XCTFail("not cleared at the cap") }
        XCTAssertTrue(p.isReplacing)
    }

    func testAutoFixStartsAgainAfterTheHardCap() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        _ = forceFlushAtHardCap(&p, clock)
        clock.advance(byMilliseconds: 1000)
        _ = p.handle(F.key(d))
        let (verdict, signal) = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(verdict, .hold)
        guard case .wordEnded? = signal else { return XCTFail("auto-fix should start again") }
    }
}
