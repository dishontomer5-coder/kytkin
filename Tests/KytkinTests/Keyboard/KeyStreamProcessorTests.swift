// P2-12: KeyStreamProcessor verdicts, markers, buffer rules, double-Shift from device bits, and resets.
// Hold-back timing lives in HoldBackTests.

import XCTest

final class KeyStreamProcessorTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2

    private func processor(mode: TapMode = .active) -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.mode = mode
        return KeyStreamProcessor(config: config, clock: FakeClock())
    }

    /// Feeds events and returns every non-nil signal.
    @discardableResult
    private func feed(_ p: inout KeyStreamProcessor, _ events: [KeyEvent]) -> [KeySignal] {
        events.compactMap { p.handle($0).1 }
    }

    private func doubleShifts(_ signals: [KeySignal]) -> Int {
        signals.filter { if case .doubleShift = $0 { return true } else { return false } }.count
    }

    // MARK: - Markers

    func testMarkersClassifyUserData() {
        XCTAssertEqual(EventOrigin(userData: 0x4B59544B), .ours)
        XCTAssertEqual(EventOrigin(userData: 0x4B595250), .replay)
        XCTAssertEqual(EventOrigin(userData: 0), .user)
        XCTAssertEqual(EventOrigin.ours.marker, 0x4B59544B)
        XCTAssertEqual(EventOrigin.replay.marker, 0x4B595250)
        XCTAssertNil(EventOrigin.user.marker)
    }

    func testOursPassesAndIsNeverBuffered() {
        var p = processor()
        let (verdict, signal) = p.handle(F.key(a, origin: .ours))
        XCTAssertEqual(verdict, .pass)
        XCTAssertNil(signal)
        XCTAssertTrue(p.buffer.isEmpty)
        // Even an "invalidating" key of ours leaves the user's buffer alone.
        _ = p.handle(F.key(s))
        _ = p.handle(F.key(KeyCode.leftArrow, origin: .ours))
        XCTAssertEqual(p.buffer.strokeCount, 1)
    }

    func testReplayIsBufferedAsUserTyping() {
        var p = processor()
        _ = p.handle(F.key(a, origin: .replay))
        XCTAssertEqual(Array(p.buffer.currentWord), [Stroke(keyCode: a, layer: .plain)])
    }

    func testOursFlagsDontDisturbShiftTracking() {
        var p = processor()
        // Our posted events carry flags = [] while the user may hold Shift (R4 §5).
        let events = [F.flags(KeyCode.leftShift, F.left, at: 0),
                      F.flags(KeyCode.leftShift, 0, at: 10, origin: .ours),
                      F.flags(KeyCode.leftShift, 0, at: 50)] + F.shiftTap(.left, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 1)
    }

    func testOursIsNotHeldDuringReplacement() {
        var p = processor()
        feed(&p, F.doubleShift())
        XCTAssertTrue(p.isReplacing)
        XCTAssertEqual(p.handle(F.key(a, origin: .ours)).0, .pass)
        XCTAssertEqual(p.heldCount, 0)
    }

    // MARK: - Buffer

    func testLettersAreBufferedWithTheirLayer() {
        var p = processor()
        _ = p.handle(F.key(a))
        _ = p.handle(F.key(s, flags: KeyEvent.shiftMask | KeyEvent.leftShiftDeviceBit))
        _ = p.handle(F.key(d, capsLock: true))
        _ = p.handle(F.key(a, flags: KeyEvent.optionMask))
        _ = p.handle(F.key(s, flags: KeyEvent.optionMask | KeyEvent.shiftMask))
        XCTAssertEqual(p.buffer.currentWord.map(\.layer), [.plain, .shift, .capsLock, .option, .shiftOption])
    }

    func testKeyUpIsIgnored() {
        var p = processor()
        XCTAssertEqual(p.handle(F.keyUp(a)).0, .pass)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testWhitespaceEmitsWordBoundaryOnlyAfterAWord() {
        var p = processor()
        XCTAssertNil(p.handle(F.key(KeyCode.space)).1)
        _ = p.handle(F.key(a))
        let (verdict, signal) = p.handle(F.key(KeyCode.space))
        XCTAssertEqual(verdict, .pass)
        XCTAssertEqual(signal, .wordBoundary)
        _ = p.handle(F.key(s))
        _ = p.handle(F.key(KeyCode.space))
        _ = p.handle(F.key(d))
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).1, .wordBoundary)
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(F.key(KeyCode.space)).1, .wordBoundary)
        XCTAssertEqual(p.buffer.wordCount, 2, "current (empty) word + 2 previous; the oldest was dropped")
        // P2-59: Return and Tab still emit the boundary (the learner), but they end the buffer.
        _ = p.handle(F.key(s))
        XCTAssertEqual(p.handle(F.key(KeyCode.returnKey)).1, .wordBoundary)
        XCTAssertTrue(p.buffer.isEmpty)
        _ = p.handle(F.key(d))
        XCTAssertEqual(p.handle(F.key(KeyCode.tab)).1, .wordBoundary)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testBackspaceRemovesAStroke() {
        var p = processor()
        feed(&p, [F.key(a), F.key(s), F.key(KeyCode.delete)])
        XCTAssertEqual(p.buffer.strokeCount, 1)
    }

    func testEscapeAndFunctionKeysTypeNothing() {
        var p = processor()
        feed(&p, [F.key(a), F.key(KeyCode.escape), F.key(122)])
        XCTAssertEqual(p.buffer.strokeCount, 1)
    }

    func testNavigationKeysInvalidate() {
        let keys = [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow,
                    KeyCode.home, KeyCode.end, KeyCode.pageUp, KeyCode.pageDown, KeyCode.forwardDelete]
        for key in keys {
            var p = processor()
            _ = p.handle(F.key(a))
            let (verdict, signal) = p.handle(F.key(key))
            XCTAssertEqual(verdict, .pass)
            XCTAssertEqual(signal, .bufferInvalidated, "key \(key)")
            XCTAssertTrue(p.buffer.isEmpty, "key \(key)")
        }
    }

    func testShortcutInvalidates() {
        var p = processor()
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(F.key(s, command: true)).1, .bufferInvalidated)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testOptionBackspaceInvalidates() {
        var p = processor()
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(F.key(KeyCode.delete, flags: KeyEvent.optionMask)).1, .bufferInvalidated)
    }

    func testMouseDownInvalidates() {
        var p = processor()
        _ = p.handle(F.key(a))
        let (verdict, signal) = p.handle(F.pointer())
        XCTAssertEqual(verdict, .pass)
        XCTAssertEqual(signal, .bufferInvalidated)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testInvalidationOfAnEmptyBufferSendsNothing() {
        var p = processor()
        XCTAssertNil(p.handle(F.pointer()).1)
        XCTAssertNil(p.handle(F.key(KeyCode.leftArrow)).1)
    }

    func testTapResetEventInvalidates() {
        var p = processor()
        _ = p.handle(F.key(a))
        XCTAssertEqual(p.handle(KeyEvent(kind: .tapReset)).1, .bufferInvalidated)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testEveryResetReasonClearsTheBuffer() {
        let reasons: [ResetReason] = [.contextChange, .secureInputOn, .tapReEnabled, .modeChange, .inputSourceChanged]
        for reason in reasons {
            var p = processor()
            _ = p.handle(F.key(a))
            p.reset(reason)
            XCTAssertTrue(p.buffer.isEmpty, "\(reason)")
        }
    }

    func testInputSourceChange() {
        var p = processor()
        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        _ = p.handle(F.key(a))
        p.inputSourceChanged(to: hebrew, isOurs: true)
        XCTAssertEqual(p.buffer.strokeCount, 1, "our own after-convert switch keeps the buffer")
        XCTAssertEqual(p.inputSource, hebrew)
        p.inputSourceChanged(to: InputSourceID("com.apple.keylayout.ABC"), isOurs: false)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    func testSetModeResets() {
        var p = processor()
        _ = p.handle(F.key(a))
        p.setMode(.listenOnly)
        XCTAssertEqual(p.mode, .listenOnly)
        XCTAssertTrue(p.buffer.isEmpty)
    }

    // MARK: - Double-Shift

    func testDoubleShiftSignalCarriesTheSnapshot() {
        var p = processor()
        let abc = InputSourceID("com.apple.keylayout.ABC")
        p.inputSourceChanged(to: abc, isOurs: true)
        feed(&p, [F.key(a), F.key(KeyCode.space), F.key(s), F.key(d)])
        var verdicts: [TapVerdict] = []
        var signals: [KeySignal] = []
        for e in F.doubleShift(at: 1000) {
            let (v, sig) = p.handle(e)
            verdicts.append(v)
            if let sig { signals.append(sig) }
        }
        XCTAssertEqual(verdicts, [.pass, .pass, .pass, .pass], "Shift is never swallowed")
        let expected = WordSnapshot(strokes: [Stroke(keyCode: s, layer: .plain), Stroke(keyCode: d, layer: .plain)],
                                    previousWords: [[Stroke(keyCode: a, layer: .plain)]], renderedIn: abc, isValid: true)
        XCTAssertEqual(signals, [.doubleShift(expected, gen: 1)])
    }

    func testDoubleShiftFiresOnRightSideToo() {
        var p = processor()
        let events = F.shiftTap(.right, down: 0, up: 40) + F.shiftTap(.right, down: 120, up: 160)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 1)
    }

    func testDoubleShiftUsesEventTimestampsNotArrivalTime() {
        // The fake clock never moves; only the event timestamps say the taps were 1 s apart.
        var p = processor()
        let events = F.shiftTap(.left, down: 0, up: 50) + F.shiftTap(.left, down: 1050, up: 1100)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }

    func testMaskShiftAloneIsNotAShiftEdge() {
        // Only 0x20000 (device-independent Shift) changes: no device bit, so no press or release.
        var p = processor()
        let events = [F.flags(KeyCode.leftShift, KeyEvent.shiftMask, at: 0), F.flags(KeyCode.leftShift, 0, at: 50),
                      F.flags(KeyCode.leftShift, KeyEvent.shiftMask, at: 150), F.flags(KeyCode.leftShift, 0, at: 200)]
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }

    func testReleasingOneShiftWhileTheOtherIsHeldIsSeen() {
        // .maskShift stays set while right Shift is held; the left device bit still shows the release.
        var p = processor()
        let both = F.left | F.right
        let events = [F.flags(KeyCode.rightShift, F.right, at: 0),
                      F.flags(KeyCode.leftShift, both, at: 10),
                      F.flags(KeyCode.leftShift, F.right, at: 40),
                      F.flags(KeyCode.leftShift, both, at: 100),
                      F.flags(KeyCode.leftShift, F.right, at: 140),
                      F.flags(KeyCode.rightShift, 0, at: 200)]
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0, "a chord with the other Shift is not a double tap")
    }

    func testKeyBetweenTapsCancels() {
        var p = processor()
        let events = F.shiftTap(.left, down: 0, up: 50) + [F.key(a, at: 100)] + F.shiftTap(.left, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }

    func testOtherModifierCancels() {
        var p = processor()
        let cmd: UInt16 = 55
        let events = F.shiftTap(.left, down: 0, up: 50) + [F.flags(cmd, 0x100000, at: 80), F.flags(cmd, 0, at: 90)]
            + F.shiftTap(.left, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }

    func testClickBetweenTapsCancels() {
        var p = processor()
        let events = F.shiftTap(.left, down: 0, up: 50) + [F.pointer(at: 100)] + F.shiftTap(.left, down: 150, up: 200)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }

    func testDoubleShiftDisabled() {
        var config = KeyProcessorConfig()
        config.doubleShiftEnabled = false
        var p = KeyStreamProcessor(config: config, clock: FakeClock())
        XCTAssertEqual(doubleShifts(feed(&p, F.doubleShift())), 0)
        XCTAssertFalse(p.isReplacing)
    }

    func testDoubleShiftWorksWithEmptyBuffer() {
        // Secure Input: no keyDowns arrive, but flagsChanged does, so double-Shift still toggles (R4 §3).
        var p = processor()
        p.reset(.secureInputOn)
        let signals = feed(&p, F.doubleShift())
        guard case let .doubleShift(snap, _)? = signals.first else { return XCTFail("no signal") }
        XCTAssertFalse(snap.isValid)
    }

    func testGenerationsIncrease() {
        var p = processor(mode: .listenOnly)
        let gens = feed(&p, F.doubleShift(at: 0) + F.doubleShift(at: 1000)).compactMap { sig -> UInt64? in
            if case let .doubleShift(_, gen) = sig { return gen } else { return nil }
        }
        XCTAssertEqual(gens, [1, 2])
    }

    func testResetReseedsAHeldShift() {
        // P2-11 QA: left Shift is held across a reset. Its release is a real edge, and it can't count as a tap.
        var p = processor()
        p.reset(.contextChange, deviceFlags: F.left)
        let events = [F.flags(KeyCode.leftShift, 0, at: 20)] + F.shiftTap(.left, down: 100, up: 150)
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0, "release of a Shift held across the reset + one tap")
        XCTAssertEqual(doubleShifts(feed(&p, F.shiftTap(.left, down: 250, up: 300))), 1)
    }

    func testResetReseedSpoilsAChordWithTheHeldShift() {
        var p = processor()
        p.reset(.tapReEnabled, deviceFlags: F.left)
        let both = F.left | F.right
        let events = [F.flags(KeyCode.rightShift, both, at: 0), F.flags(KeyCode.rightShift, F.left, at: 40),
                      F.flags(KeyCode.rightShift, both, at: 100), F.flags(KeyCode.rightShift, F.left, at: 140)]
        XCTAssertEqual(doubleShifts(feed(&p, events)), 0)
    }
}
