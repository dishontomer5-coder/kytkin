// P2-12 QA: hold-back paths where an event could be lost, duplicated or reordered (001 §7 B2/B3, R5).
// Each test pins one path: a mode change mid-hold, an abort while the worker is posting, a full aborted FIFO,
// and the forced flush after the hard cap.

import XCTest

final class HoldBackQATests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")

    private func makeProcessor(_ clock: FakeClock, autoFix: Bool = false) -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.autoFixEnabled = autoFix
        return KeyStreamProcessor(config: config, clock: clock)
    }

    private func startConvert(_ p: inout KeyStreamProcessor) -> UInt64 {
        var gen: UInt64 = 0
        for e in F.doubleShift() {
            if case let .doubleShift(_, g)? = p.handle(e).1 { gen = g }
        }
        XCTAssertTrue(p.isReplacing)
        return gen
    }

    // MARK: - Never hold outside active mode

    /// A listen-only tap can't swallow, so a `.hold` there would deliver the key now *and* replay it later.
    func testAfterSwitchingToListenOnlyKeysAreNeverHeld() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        XCTAssertEqual(p.handle(F.key(a)).0, .hold)
        p.setMode(.listenOnly)
        XCTAssertEqual(p.handle(F.key(s)).0, .pass, "a listen-only tap can't hold: .hold would duplicate the key")
        XCTAssertEqual(p.handle(F.keyUp(s)).0, .pass)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.map(\.event.keyCode), [a],
                       "no more holding is possible, so flush now even if the worker posts")
        XCTAssertNil(p.pollFlush())
    }

    // MARK: - A full, aborted FIFO

    /// The FIFO filled and aborted, and a word-ending key arrives before the adapter polled. It must not start a
    /// new hold-back over the old events (the trigger would be dropped and the next fix would drop a user key).
    func testFullAbortedQueueNeverStartsAnAutoFix() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        _ = p.handle(F.key(a))
        _ = startConvert(&p)
        for _ in 0..<32 { XCTAssertEqual(p.handle(F.key(d)).0, .hold) }
        XCTAssertEqual(p.heldCount, 32)
        let (verdict, signal) = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(verdict, .pass, "nothing can be held any more: the key must pass, never vanish")
        XCTAssertNil(signal.flatMap { if case .wordEnded = $0 { return $0 } else { return nil } })
        XCTAssertEqual(p.pollFlush()?.count, 32)
        XCTAssertNil(p.pollFlush())
    }

    // MARK: - Abort while the worker is posting (B3)

    func testAbortedReplacementKeepsItsGenerationForTheCommit() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let gen = startConvert(&p)
        p.reset(.contextChange)
        XCTAssertFalse(p.isReplacing)
        XCTAssertEqual(p.activeGeneration, gen, "the adapter claims the flush for this gen (B3)")
        XCTAssertEqual(p.nextDeadlineNanos, 0, "due now")
    }

    /// The worker already won the commit and is posting: flushing held keys now would interleave them with its
    /// backspaces and text (R5: `hello  שלום`). Wait for its finish instead, still holding new keys in order.
    func testAbortWhileTheWorkerIsPostingWaitsForItsFinish() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = p.handle(F.key(d))
        let gen = startConvert(&p)
        _ = p.handle(F.key(a))
        p.reset(.contextChange)
        XCTAssertEqual(p.handle(F.key(s)).0, .hold)
        XCTAssertNil(p.pollFlush(postingStarted: true))
        let held = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: [Stroke(keyCode: d, layer: .plain)])
        XCTAssertEqual(held.map(\.event.keyCode), [a, s])
        XCTAssertTrue(p.buffer.isEmpty, "the reset already cleared the buffer; the finish must not refill it")
        XCTAssertNil(p.inputSource, "an aborted finish doesn't re-render")
        XCTAssertNil(p.pollFlush())
    }

    func testAbortWhilePostingStillFlushesWhenTheQueueIsFull() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = startConvert(&p)
        _ = p.handle(F.key(a, command: true)) // shortcut aborts
        XCTAssertNil(p.pollFlush(postingStarted: true))
        for _ in 0..<31 { XCTAssertEqual(p.handle(F.key(d)).0, .hold) }
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 32, "full: never wait, never drop")
    }

    func testAbortWhilePostingIsForcedOutAtTheHardCap() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        let gen = startConvert(&p)
        _ = p.handle(F.key(a))
        _ = p.handle(F.pointer())
        XCTAssertNil(p.pollFlush(postingStarted: true))
        XCTAssertEqual(p.nextDeadlineNanos, 1000 * F.ms)
        clock.advance(byMilliseconds: 1000)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 1)
        XCTAssertEqual(p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil), [])
    }

    /// Auto-fix aborted by a click after the worker posted its fix (which includes its own Space, marked `ours`):
    /// the held trigger must not be replayed too, or the user gets two spaces.
    func testAbortedAutoFixThatPostedDoesNotReplayTheTrigger() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        _ = p.handle(F.key(a))
        guard case let .wordEnded(_, gen)? = p.handle(F.key(KeyCode.space)).1 else { return XCTFail("no trigger") }
        _ = p.handle(F.key(d))
        _ = p.handle(F.pointer())
        XCTAssertNil(p.pollFlush(postingStarted: true))
        let held = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: [Stroke(keyCode: a, layer: .plain)])
        XCTAssertEqual(held.map(\.event.keyCode), [d])
        XCTAssertTrue(p.buffer.isEmpty)
    }

    // MARK: - Forced flush after the hard cap

    /// After a forced flush the worker may have posted part of its text, so the buffer can't be trusted.
    func testForcedFlushAfterTheHardCapInvalidatesTheBuffer() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = p.handle(F.key(d))
        _ = startConvert(&p)
        _ = p.handle(F.key(a))
        clock.advance(byMilliseconds: 400)
        XCTAssertNil(p.pollFlush(postingStarted: true))
        clock.advance(byMilliseconds: 1000)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 1)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testPlainDeadlineFlushKeepsTheBuffer() {
        let clock = FakeClock()
        var p = makeProcessor(clock)
        _ = p.handle(F.key(d))
        _ = startConvert(&p)
        clock.advance(byMilliseconds: 400)
        XCTAssertEqual(p.pollFlush()?.count, 0)
        XCTAssertEqual(p.buffer.strokeCount, 1, "nothing was posted, so the screen still matches")
    }

    // MARK: - Exactly once, in order, across many replacements

    /// Every user key goes out exactly once: passed, or held and returned once by a flush or a finish.
    /// P2-35: also, no replacement starts while a force-flushed worker may still be posting. Every 5th generation's
    /// worker hangs while posting, so it is forced out (hard cap or full FIFO); half of those finish late, the rest never.
    func testEveryHeldKeyComesOutExactlyOnceInOrder() {
        let clock = FakeClock()
        var p = makeProcessor(clock, autoFix: true)
        var out: [UInt16] = []
        var sent: [UInt16] = []
        var gen: UInt64?
        var heldCount = 0
        var code: UInt16 = 0
        var stale: (gen: UInt64, until: UInt64)?
        var starts = 0, refusedWindows = 0, refusals = 0
        func isHung(_ g: UInt64) -> Bool { g % 5 == 0 }
        func staleMayPost() -> Bool { stale.map { clock.nowNanos < $0.until } ?? false }
        // P2-35: a new start is only allowed when no stale worker may post.
        func started(_ g: UInt64) {
            starts += 1
            if let st = stale, clock.nowNanos < st.until { XCTFail("gen \(g) started while stale gen \(st.gen) may post") }
            stale = nil
            gen = g
        }
        for step in 0..<5_000 {
            let e: KeyEvent
            switch step % 37 {
            case 0: e = F.key(KeyCode.space)
            case 5: e = F.pointer()
            case 11: e = F.key(s, command: true)
            default:
                code = (code + 1) % 30
                e = F.key(code == KeyCode.delete ? 0 : code)
            }
            if step % 53 == 0 {
                var fired = false
                for ev in F.doubleShift(at: UInt64(step) * 1000) {
                    if case let .doubleShift(_, g)? = p.handle(ev).1 { started(g); fired = true }
                }
                if !fired, p.activeGeneration == nil, staleMayPost() { refusals += 1 }
            }
            if e.kind == .keyDown { sent.append(e.keyCode) }
            let (verdict, signal) = p.handle(e)
            if case let .wordEnded(_, g)? = signal { started(g) }
            if verdict == .pass, e.kind == .keyDown { out.append(e.keyCode) }
            if verdict == .hold { heldCount += 1 }
            if step % 7 == 0, let g = gen, !(isHung(g) && p.activeGeneration == g) {
                // A hung worker finishes only after it was forced out (a stale finish), and only for half of them.
                if !isHung(g) || g % 10 == 0 {
                    out += p.finishReplacement(gen: g, newRendering: nil, bufferAfter: nil).map(\.event.keyCode)
                    if stale?.gen == g { stale = nil }
                }
                gen = nil
            }
            if step % 13 == 0 { p.reset(.contextChange) }
            clock.advance(byMilliseconds: 20)
            let active = p.activeGeneration
            let posting = active.map(isHung) ?? false || step % 3 == 0
            if let flushed = p.pollFlush(postingStarted: posting) {
                out += flushed.map(\.event.keyCode)
                if posting, let active {
                    stale = (active, clock.nowNanos + KeyProcessorConfig().postingHardCapNanos)
                    refusedWindows += 1
                }
            }
        }
        clock.advance(bySeconds: 5)
        out += (p.pollFlush() ?? []).map(\.event.keyCode)
        XCTAssertEqual(p.heldCount, 0)
        XCTAssertGreaterThan(heldCount, 100, "the run must exercise hold-back")
        XCTAssertEqual(out, sent)
        XCTAssertGreaterThan(starts, 50, "the run must start many replacements")
        XCTAssertGreaterThan(refusedWindows, 5, "the run must force-flush under a posting worker")
        XCTAssertGreaterThan(refusals, 0, "the run must refuse a double-Shift during a stale window")
    }
}
