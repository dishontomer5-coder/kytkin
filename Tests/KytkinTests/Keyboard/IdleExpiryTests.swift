// P3-34 (3): the typed-text buffer (and a parked terminal buffer) is forgotten after 3 idle minutes with no key.
// Pure value tests with a fake clock; nothing is installed or posted.

import XCTest

final class IdleExpiryTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
    private let terminalPID: Int32 = 501
    private let limitSeconds = KeyStreamProcessor.idleExpiryNanos / 1_000_000_000
    private var clock: FakeClock!

    private func processor() -> KeyStreamProcessor {
        clock = FakeClock(nowNanos: 1_000_000_000)
        var config = KeyProcessorConfig()
        config.mode = .active
        var p = KeyStreamProcessor(config: config, clock: clock)
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    private func type(_ p: inout KeyStreamProcessor, _ codes: [UInt16]) {
        for c in codes { _ = p.handle(F.key(c)) }
    }

    private func snapshot(_ p: inout KeyStreamProcessor) -> WordSnapshot? {
        for e in F.doubleShift(at: 5_000) {
            if case let .doubleShift(snap, gen)? = p.handle(e).1 {
                _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
                return snap
            }
        }
        XCTFail("no double-Shift")
        return nil
    }

    func testTheLimitIsThreeMinutes() {
        XCTAssertEqual(limitSeconds, 180)
    }

    func testJustUnderTheLimitTheBufferIsKept() {
        var p = processor()
        type(&p, [a, s, d])
        clock.advance(bySeconds: limitSeconds - 1)
        XCTAssertNil(p.expireIfIdle())
        XCTAssertEqual(snapshot(&p)?.hasRun, true)
    }

    func testAfterTheLimitThePollForgetsTheBuffer() {
        var p = processor()
        type(&p, [a, s, d])
        clock.advance(bySeconds: limitSeconds)
        XCTAssertEqual(p.expireIfIdle(), .bufferInvalidated)
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertNil(p.expireIfIdle(), "nothing left to forget")
    }

    func testADoubleShiftAfterALongPauseSeesNoOldBufferEvenWithoutThePoll() {
        var p = processor()
        type(&p, [a, s, d])
        clock.advance(bySeconds: limitSeconds + 5)
        XCTAssertEqual(snapshot(&p)?.hasRun, false, "the controller just switches")
    }

    func testAKeyAfterALongPauseStartsAFreshBuffer() {
        var p = processor()
        type(&p, [a, s, d])
        clock.advance(bySeconds: limitSeconds + 5)
        let (verdict, signal) = p.handle(F.key(a))
        XCTAssertEqual(verdict, .pass)
        XCTAssertEqual(signal, .bufferInvalidated)
        XCTAssertFalse(p.buffer.isEmpty, "the new key is kept")
    }

    func testEachKeyRestartsTheIdleTime() {
        var p = processor()
        type(&p, [a])
        clock.advance(bySeconds: limitSeconds - 10)
        type(&p, [s])
        clock.advance(bySeconds: limitSeconds - 10)
        XCTAssertNil(p.expireIfIdle())
        XCTAssertFalse(p.buffer.isEmpty)
    }

    func testAParkedTerminalBufferIsForgottenTooAndNeverRestored() {
        var p = processor()
        p.contextChanged(terminalPID: terminalPID)
        type(&p, [a, s, d])
        p.contextChanged(terminalPID: nil)   // parked
        XCTAssertTrue(p.hasParkedBuffer)
        clock.advance(bySeconds: limitSeconds)
        _ = p.expireIfIdle()
        XCTAssertFalse(p.hasParkedBuffer)
        p.contextChanged(terminalPID: terminalPID)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testAParkedBufferIsNotRestoredAfterTheLimitEvenWithoutThePoll() {
        var p = processor()
        p.contextChanged(terminalPID: terminalPID)
        type(&p, [a, s, d])
        p.contextChanged(terminalPID: nil)
        clock.advance(bySeconds: limitSeconds + 1)
        p.contextChanged(terminalPID: terminalPID)
        XCTAssertTrue(p.buffer.isEmpty)
        XCTAssertFalse(p.hasParkedBuffer)
    }

    func testAParkedBufferComesBackWithinTheLimit() {
        var p = processor()
        p.contextChanged(terminalPID: terminalPID)
        type(&p, [a, s, d])
        p.contextChanged(terminalPID: nil)
        clock.advance(bySeconds: 60)
        p.contextChanged(terminalPID: terminalPID)
        XCTAssertFalse(p.buffer.isEmpty)
    }

    func testNothingExpiresDuringAReplacement() {
        var p = processor()
        type(&p, [a, s, d])
        var started = false
        for e in F.doubleShift(at: 5_000) { if case .doubleShift? = p.handle(e).1 { started = true } }
        XCTAssertTrue(started)
        clock.advance(bySeconds: limitSeconds + 1)
        XCTAssertNil(p.expireIfIdle())
    }
}
