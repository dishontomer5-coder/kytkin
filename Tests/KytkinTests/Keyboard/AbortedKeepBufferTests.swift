// P2-60 (001 §12.3 X5): an aborted or force-flushed generation never leaves a kept buffer. Its finish is ignored, so
// nothing would state the buffer after it, and its after-convert switch arrives with `isOurs: true` ("keep the
// buffer"). The processor forgets the buffer on the abort and ignores `isOurs` until the next replacement starts.
// Both arrival orders (finish first, or the switch notification first) are pinned. Pure value tests, fake clock.

import XCTest

final class AbortedKeepBufferTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")

    private func processor(_ clock: FakeClock) -> KeyStreamProcessor {
        var p = KeyStreamProcessor(config: KeyProcessorConfig(), clock: clock)
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    private func type(_ p: inout KeyStreamProcessor, _ codes: [UInt16]) {
        for c in codes { _ = p.handle(F.key(c)) }
    }

    /// Types "a s", double-Shifts, and returns the running generation.
    private func startConvert(_ p: inout KeyStreamProcessor, at t: UInt64 = 1_000) -> UInt64? {
        type(&p, [a, KeyCode.space, s])
        for e in F.doubleShift(at: t) {
            if case let .doubleShift(_, gen)? = p.handle(e).1 { return gen }
        }
        XCTFail("no double-Shift")
        return nil
    }

    private enum Abort: CaseIterable { case shortcut, fullFIFO }

    /// Aborts the running convert while its worker posts. The worker has already switched (in main) or will.
    private func abort(_ p: inout KeyStreamProcessor, _ how: Abort) -> KeySignal? {
        switch how {
        case .shortcut:
            return p.handle(F.key(d, command: true)).1
        case .fullFIFO:
            var last: KeySignal?
            var n = 0   // QA (P3-7): bounded, so a regression fails instead of hanging the test run
            while p.heldCount < 32, n < 1_000 { last = p.handle(F.key(d)).1; n += 1 }
            XCTAssertEqual(p.heldCount, 32, "the FIFO fills")
            return last
        }
    }

    // MARK: - The abort itself

    func testShortcutAndFullFIFOAbortsForgetTheBuffer() {
        for how in Abort.allCases {
            let clock = FakeClock()
            var p = processor(clock)
            guard startConvert(&p) != nil else { return }
            XCTAssertFalse(p.buffer.isEmpty)
            XCTAssertEqual(abort(&p, how), .bufferInvalidated, "\(how): the invalidation is reported")
            XCTAssertTrue(p.buffer.isEmpty, "\(how)")
            XCTAssertTrue(p.keepBufferRevoked, "\(how)")
            XCTAssertFalse(p.isReplacing, "\(how)")
        }
    }

    func testClickStillReportsTheInvalidationWhileReplacing() {
        let clock = FakeClock()
        var p = processor(clock)
        guard startConvert(&p) != nil else { return }
        XCTAssertEqual(p.handle(F.pointer(at: 1_500)).1, .bufferInvalidated)
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertTrue(p.keepBufferRevoked)
    }

    // MARK: - Finish first, then the switch notification

    /// The worker wrote and switched; the finish (keep everything, re-rendered, or forget) is ignored because the gen
    /// was aborted; then a letter is typed (in the old layout) before the late `isOurs` notification lands.
    func testFinishFirstThenOurSwitchKeepsNothing() {
        for how in Abort.allCases {
            for bufferAfter in [nil, [] as [Stroke]] {
                let clock = FakeClock()
                var p = processor(clock)
                guard let gen = startConvert(&p) else { return }
                _ = abort(&p, how)
                if how == .fullFIFO { XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 32) }
                _ = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: bufferAfter)
                XCTAssertTrue(p.buffer.isEmpty, "\(how): the ignored finish doesn't refill")
                XCTAssertEqual(p.inputSource, abc, "\(how): an aborted finish doesn't re-render")
                type(&p, [a])                       // typed in ABC, before the notification
                p.inputSourceChanged(to: hebrew, isOurs: true)
                XCTAssertTrue(p.buffer.isEmpty, "\(how), \(String(describing: bufferAfter)): no stale kept buffer")
                XCTAssertNil(p.bufferRendering)
                XCTAssertEqual(p.inputSource, hebrew)
            }
        }
    }

    // MARK: - The switch notification first, then the finish

    func testOurSwitchFirstThenFinishKeepsNothing() {
        for how in Abort.allCases {
            let clock = FakeClock()
            var p = processor(clock)
            guard let gen = startConvert(&p) else { return }
            _ = abort(&p, how)
            p.inputSourceChanged(to: hebrew, isOurs: true)
            XCTAssertTrue(p.buffer.isEmpty, "\(how)")
            XCTAssertEqual(p.activeGeneration, gen, "\(how): the held keys still wait for the flush or finish")
            _ = p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil, bufferRenderedIn: nil)
            XCTAssertTrue(p.buffer.isEmpty, "\(how)")
            XCTAssertNil(p.bufferRendering)
            XCTAssertEqual(p.inputSource, hebrew)
        }
    }

    /// The switch landed before the abort (main switched, then the user pressed ⌘ before the finish hop arrived):
    /// the notification kept the buffer, so the abort itself must forget it; the AX-run finish's `[]` is ignored.
    func testOurSwitchBeforeTheAbortIsForgottenByTheAbort() {
        for how in Abort.allCases {
            let clock = FakeClock()
            var p = processor(clock)
            guard let gen = startConvert(&p) else { return }
            p.inputSourceChanged(to: hebrew, isOurs: true)
            XCTAssertFalse(p.buffer.isEmpty, "not aborted yet: our switch keeps it")
            _ = abort(&p, how)
            XCTAssertTrue(p.buffer.isEmpty, "\(how)")
            _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: [])
            XCTAssertTrue(p.buffer.isEmpty, "\(how)")
        }
    }

    // MARK: - Force-flushed at the hard cap (no abort)

    func testHardCapFlushRevokesTheKeepBufferSwitch() {
        let clock = FakeClock()
        var p = processor(clock)
        guard let gen = startConvert(&p) else { return }
        _ = p.handle(F.key(d))
        clock.advance(byMilliseconds: 400)
        XCTAssertNil(p.pollFlush(postingStarted: true), "deadline under a posting worker: wait for the cap")
        clock.advance(byMilliseconds: 1_000)
        XCTAssertEqual(p.pollFlush(postingStarted: true)?.count, 1)
        type(&p, [a])                                // typed in ABC after the forced flush
        p.inputSourceChanged(to: hebrew, isOurs: true)
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertEqual(p.finishReplacement(gen: gen, newRendering: hebrew, bufferAfter: nil), [])
        XCTAssertTrue(p.buffer.isEmpty)
    }

    // MARK: - The next generation trusts its own switch again

    func testNextGenerationClearsTheRevocation() {
        let clock = FakeClock()
        var p = processor(clock)
        guard let gen1 = startConvert(&p) else { return }
        _ = abort(&p, .shortcut)
        _ = p.finishReplacement(gen: gen1, newRendering: nil, bufferAfter: nil)
        clock.advance(byMilliseconds: 2_000)
        guard let gen2 = startConvert(&p, at: 5_000) else { return }
        XCTAssertFalse(p.keepBufferRevoked)
        _ = p.finishReplacement(gen: gen2, newRendering: hebrew, bufferAfter: nil)
        p.inputSourceChanged(to: hebrew, isOurs: true)
        XCTAssertEqual(p.buffer.strokeCount, 2, "a finished convert's own switch keeps the re-rendered buffer")
    }
}
