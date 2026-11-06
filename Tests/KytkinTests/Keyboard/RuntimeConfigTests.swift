// P2-50: runtime settings changes (001 §12 W6) and a Shift held across a tap replacement.
// Processor rules first (pure), then the same through KeyTapEngine with a fake backend (no tap, nothing posted).

import CoreGraphics
import XCTest

final class RuntimeConfigTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1

    private func processor(clock: FakeClock = FakeClock()) -> KeyStreamProcessor {
        KeyStreamProcessor(config: KeyProcessorConfig(), clock: clock)
    }

    @discardableResult
    private func feed(_ p: inout KeyStreamProcessor, _ events: [KeyEvent]) -> [KeySignal] {
        events.compactMap { p.handle($0).1 }
    }

    private func doubleShifts(_ signals: [KeySignal]) -> Int {
        signals.filter { if case .doubleShift = $0 { return true } else { return false } }.count
    }

    // MARK: - updateConfig: what it ignores

    func testUpdateConfigIgnoresModeAndCapacity() {
        let clock = FakeClock()
        var p = processor(clock: clock)
        var c = KeyProcessorConfig()
        c.mode = .off
        c.holdBackCapacity = 4
        c.autoFixEnabled = true
        p.updateConfig(c)
        XCTAssertEqual(p.mode, .active, "the mode follows the installed tap, not the settings")
        XCTAssertEqual(p.config.mode, .active)
        XCTAssertEqual(p.config.holdBackCapacity, HoldBackQueue.maxCapacity)
        XCTAssertTrue(p.config.autoFixEnabled, "everything else is taken")

        // The FIFO keeps its size: 10 keys are held without the overflow abort a capacity of 4 would cause.
        feed(&p, F.doubleShift())
        for _ in 0..<10 { XCTAssertEqual(p.handle(F.key(a)).0, .hold) }
        XCTAssertEqual(p.heldCount, 10)
        XCTAssertTrue(p.isReplacing)
    }

    // MARK: - updateConfig: the detector restarts

    func testAHalfDoneDoubleShiftDoesNotFireAfterAConfigChange() {
        var control = processor()
        XCTAssertEqual(doubleShifts(feed(&control, F.doubleShift())), 1, "control: the same taps fire")

        var p = processor()
        feed(&p, F.shiftTap(.left, down: 0, up: 50))
        p.updateConfig(KeyProcessorConfig())
        XCTAssertEqual(doubleShifts(feed(&p, F.shiftTap(.left, down: 150, up: 200))), 0,
                       "the first tap was under the old settings")
        XCTAssertEqual(doubleShifts(feed(&p, F.shiftTap(.left, down: 300, up: 350))), 1, "a new gesture still works")
    }

    func testAShiftHeldAcrossAConfigChangeCantCountAsATap() {
        var p = processor()
        feed(&p, [F.flags(KeyCode.leftShift, F.left, at: 0)])
        p.updateConfig(KeyProcessorConfig())
        let events = [F.flags(KeyCode.leftShift, 0, at: 50)] + F.shiftTap(.left, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0, "release of the held Shift + one tap")
        XCTAssertEqual(doubleShifts(feed(&p, F.shiftTap(.left, down: 300, up: 350))), 1)
    }

    /// Left Shift held through the change, right Shift tapped twice: still a chord, not a double tap.
    func testAShiftHeldAcrossAConfigChangeStillMakesAChord() {
        let both = F.left | F.right
        let rightTwice = [F.flags(KeyCode.rightShift, both, at: 100), F.flags(KeyCode.rightShift, F.left, at: 150),
                          F.flags(KeyCode.rightShift, both, at: 250), F.flags(KeyCode.rightShift, F.left, at: 300)]
        var p = processor()
        feed(&p, [F.flags(KeyCode.leftShift, F.left, at: 0)])
        p.updateConfig(KeyProcessorConfig())
        XCTAssertEqual(doubleShifts(feed(&p, rightTwice)), 0)
    }

    func testTheNewWindowAndSidePolicyApply() {
        var p = processor()
        var c = KeyProcessorConfig()
        c.doubleShift = DoubleShiftConfig(windowNanos: 200 * F.ms, sides: .leftOnly)
        p.updateConfig(c)
        XCTAssertEqual(p.config.doubleShift.sides, .leftOnly)
        let right = F.shiftTap(.right, down: 0, up: 50) + F.shiftTap(.right, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, right)), 0, "right Shift no longer counts")
        // A 250 ms gap fit the old 300 ms window, not the new 200 ms one.
        let slow = F.shiftTap(.left, down: 1_000, up: 1_050) + F.shiftTap(.left, down: 1_300, up: 1_350)
        XCTAssertEqual(doubleShifts(feed(&p, slow)), 0)
        XCTAssertEqual(doubleShifts(feed(&p, F.doubleShift(at: 2_000))), 1)
    }

    func testDoubleShiftCanBeTurnedOffAndOnAtRuntime() {
        var p = processor()
        var off = KeyProcessorConfig()
        off.doubleShiftEnabled = false
        p.updateConfig(off)
        XCTAssertEqual(doubleShifts(feed(&p, F.doubleShift())), 0)
        XCTAssertFalse(p.isReplacing)
        p.updateConfig(KeyProcessorConfig())
        XCTAssertEqual(doubleShifts(feed(&p, F.doubleShift(at: 1_000))), 1)
    }

    // MARK: - updateConfig: what it keeps

    func testUpdateConfigKeepsTheWordBuffer() {
        var p = processor()
        feed(&p, [F.key(a), F.key(s)])
        var c = KeyProcessorConfig()
        c.doubleShiftEnabled = false
        p.updateConfig(c)
        XCTAssertEqual(p.buffer.strokeCount, 2)
    }

    func testUpdateConfigKeepsHeldKeysAndTheArmedDeadline() {
        let clock = FakeClock(nowNanos: 10_000 * F.ms)
        var p = processor(clock: clock)
        let signals = feed(&p, F.doubleShift(at: 10_000))
        guard case let .doubleShift(_, gen)? = signals.last else { return XCTFail("no double-Shift") }
        XCTAssertEqual(p.handle(F.key(a)).0, .hold)
        let due = p.nextDeadlineNanos
        XCTAssertEqual(due, clock.nowNanos + 400 * F.ms)

        var c = KeyProcessorConfig()
        c.convertDeadlineNanos = 100 * F.ms
        c.doubleShiftEnabled = false
        p.updateConfig(c)
        XCTAssertEqual(p.nextDeadlineNanos, due, "the running replacement keeps its deadline")
        XCTAssertEqual(p.heldCount, 1)
        XCTAssertTrue(p.isReplacing)
        XCTAssertEqual(p.activeGeneration, gen)

        clock.advance(byMilliseconds: 150)
        XCTAssertNil(p.pollFlush(), "not due under the old 400 ms deadline")
        clock.advance(byMilliseconds: 250)
        XCTAssertEqual(p.pollFlush()?.count, 1)
    }

    func testTheNextReplacementUsesTheNewDeadline() {
        let clock = FakeClock(nowNanos: 10_000 * F.ms)
        var p = processor(clock: clock)
        var c = KeyProcessorConfig()
        c.convertDeadlineNanos = 100 * F.ms
        p.updateConfig(c)
        feed(&p, F.doubleShift(at: 10_000))
        XCTAssertEqual(p.nextDeadlineNanos, clock.nowNanos + 100 * F.ms)
    }

    // MARK: - setMode re-seeds a held Shift (P2-50 item 4)

    /// Both Shifts held across a mode switch; the right one is released, then the left, then one left tap. Without
    /// the flags the release of the right Shift looks like a fresh left press, so the left release + one tap fires.
    func testSetModeWithDeviceFlagsRemembersHeldShifts() {
        let after = [F.flags(KeyCode.rightShift, F.left, at: 0), F.flags(KeyCode.leftShift, 0, at: 50)]
            + F.shiftTap(.left, down: 150, up: 200)

        var forgetful = processor()
        forgetful.setMode(.listenOnly)
        XCTAssertEqual(doubleShifts(feed(&forgetful, after)), 1, "control: the false double-Shift this fixes")

        var p = processor()
        p.setMode(.listenOnly, deviceFlags: F.left | F.right)
        XCTAssertEqual(doubleShifts(feed(&p, after)), 0)
        XCTAssertEqual(doubleShifts(feed(&p, F.shiftTap(.left, down: 300, up: 350))), 1)
    }

    // MARK: - Through KeyTapEngine

    private typealias T = TapEventFactory

    private func makeEngine(clock: FakeClock, backend: FakeKeyTapBackend,
                            signals: SignalLog) -> KeyTapEngine {
        let engine = KeyTapEngine(
            processor: KeyStreamProcessor(config: KeyProcessorConfig(), clock: clock), commit: HoldBackCommitLock(),
            backend: backend, clock: clock, timestamps: EventTimestampNormalizer(numer: 1, denom: 1), machNow: { 0 },
            sendSignal: { signals.append($0) }, sendStatus: { _ in })
        engine.applyMode(.active, userInitiated: true)
        return engine
    }

    func testEngineUpdateConfigKeepsHeldKeysAndTheArmedTimer() {
        let clock = FakeClock(nowNanos: 10_000 * T.ms)
        let backend = FakeKeyTapBackend()
        let signals = SignalLog()
        let engine = makeEngine(clock: clock, backend: backend, signals: signals)
        for (type, e) in T.doubleShift(at: 10_000) { backend.deliver(type, e) }
        XCTAssertEqual(signals.doubleShifts, 1)
        XCTAssertEqual(backend.deliver(.keyDown, T.key(a)), false, "held")
        let armed = backend.armedDeadline
        XCTAssertNotNil(armed)

        var c = KeyProcessorConfig()
        c.convertDeadlineNanos = 100 * T.ms
        c.doubleShiftEnabled = false
        engine.perform(.updateConfig(c))
        XCTAssertEqual(backend.armedDeadline, armed, "the timer is left alone")
        XCTAssertEqual(engine.heldCGEventCount, 1)
        XCTAssertTrue(backend.posted.isEmpty, "nothing flushed by the change")
        XCTAssertFalse(engine.processor.config.doubleShiftEnabled)

        clock.advance(byMilliseconds: 400)
        backend.fireDeadline()
        XCTAssertEqual(backend.posted.map(\.keyCode), [Int64(a)])
    }

    func testEngineUpdateConfigDropsAHalfDoneDoubleShift() {
        let clock = FakeClock(nowNanos: 10_000 * T.ms)
        let backend = FakeKeyTapBackend()
        let signals = SignalLog()
        let engine = makeEngine(clock: clock, backend: backend, signals: signals)
        let taps = T.doubleShift(at: 10_000)
        for (type, e) in taps.prefix(2) { backend.deliver(type, e) }
        engine.perform(.updateConfig(KeyProcessorConfig()))
        for (type, e) in taps.suffix(2) { backend.deliver(type, e) }
        XCTAssertEqual(signals.doubleShifts, 0)
    }

    /// P2-50 item 4: the reset after the new tap goes in passes the current device flags.
    func testATapReplacementRemembersAShiftHeldAcrossIt() {
        let clock = FakeClock(nowNanos: 10_000 * T.ms)
        let backend = FakeKeyTapBackend()
        let signals = SignalLog()
        let engine = makeEngine(clock: clock, backend: backend, signals: signals)
        backend.deviceFlags = KeyEvent.leftShiftDeviceBit | KeyEvent.rightShiftDeviceBit | KeyEvent.shiftMask
        XCTAssertEqual(engine.applyMode(.listenOnly, userInitiated: true), .listenOnly)
        backend.deviceFlags = 0
        let left = KeyEvent.leftShiftDeviceBit | KeyEvent.shiftMask
        backend.deliver(.flagsChanged, T.flagsChanged(KeyCode.rightShift, left, at: 10_000))
        backend.deliver(.flagsChanged, T.flagsChanged(KeyCode.leftShift, 0, at: 10_050))
        backend.deliver(.flagsChanged, T.flagsChanged(KeyCode.leftShift, left, at: 10_150))
        backend.deliver(.flagsChanged, T.flagsChanged(KeyCode.leftShift, 0, at: 10_200))
        XCTAssertEqual(signals.doubleShifts, 0, "the held Shifts' releases + one tap aren't a double-Shift")
        for (type, e) in T.doubleShift(at: 10_400) { backend.deliver(type, e) }
        XCTAssertEqual(signals.doubleShifts, 1)
    }
}

private final class SignalLog: @unchecked Sendable { // @unchecked: test-thread only
    private(set) var signals: [KeySignal] = []
    func append(_ s: KeySignal) { signals.append(s) }
    var doubleShifts: Int {
        signals.filter { if case .doubleShift = $0 { return true } else { return false } }.count
    }
}
