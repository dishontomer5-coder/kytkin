// P3-37 (b) (owner 2026-11-11): in a terminal the word buffer survives clicks and an app switch away and back to the same
// terminal, and still ends at Return / keypad Enter / Shift+Return / Tab / ⌃C, Secure Input, a tap re-enable, a mode
// change, or another terminal. P3-37 (a): outside terminals, after a click and an app switch away and back, a
// double-Shift still fires (with nothing remembered, so the controller just switches). Pure value tests; nothing is
// installed or posted.

import XCTest

final class TerminalMemoryTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    private let terminalPID: Int32 = 501
    private let otherTerminalPID: Int32 = 502
    private let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2

    private func processor() -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.mode = .active
        var p = KeyStreamProcessor(config: config, clock: FakeClock())
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    private func inTerminal() -> KeyStreamProcessor {
        var p = processor()
        p.contextChanged(terminalPID: terminalPID)
        return p
    }

    private func type(_ p: inout KeyStreamProcessor, _ codes: [UInt16]) {
        for c in codes { _ = p.handle(F.key(c)) }
    }

    /// The snapshot a double-Shift hands over (and the processor back to idle).
    private func snapshot(_ p: inout KeyStreamProcessor, at t: UInt64 = 5_000) -> WordSnapshot? {
        for e in F.doubleShift(at: t) {
            if case let .doubleShift(snap, gen)? = p.handle(e).1 {
                _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
                return snap
            }
        }
        XCTFail("no double-Shift")
        return nil
    }

    // MARK: - (a) the gesture still fires after a click and an app switch

    func testOutsideATerminalAClickAndAnAppSwitchLeaveNothingButDoubleShiftStillFires() {
        var p = processor()
        type(&p, [a, s, d])
        _ = p.handle(F.pointer(at: 1_000))              // click out
        p.contextChanged(terminalPID: nil)              // another app
        p.contextChanged(terminalPID: nil)              // back
        _ = p.handle(F.pointer(at: 2_000))              // click back in
        let snap = snapshot(&p)
        XCTAssertEqual(snap?.hasRun, false, "nothing remembered: the controller just switches (P2-54(a))")
    }

    func testAFocusChangeInsideTheAppStillFires() {
        var p = processor()
        type(&p, [a])
        p.contextChanged(terminalPID: nil)
        XCTAssertNotNil(snapshot(&p))
    }

    // MARK: - (b) clicks

    func testAClickInATerminalKeepsTheBufferAndMarksIt() {
        var p = inTerminal()
        type(&p, [a, s])
        let (_, signal) = p.handle(F.pointer(at: 1_000))
        XCTAssertNil(signal, "no invalidation")
        let snap = snapshot(&p)
        XCTAssertEqual(snap?.strokes.count, 2)
        XCTAssertEqual(snap?.crossedFocus, true)
    }

    func testAClickOutsideATerminalStillForgets() {
        var p = processor()
        type(&p, [a, s])
        XCTAssertEqual(p.handle(F.pointer(at: 1_000)).1, .bufferInvalidated)
        XCTAssertEqual(snapshot(&p)?.hasRun, false)
    }

    func testAClickDuringAReplacementStillAbortsAndForgets() {
        var p = inTerminal()
        type(&p, [a])
        for e in F.doubleShift(at: 1_000) { _ = p.handle(e) }
        XCTAssertTrue(p.isReplacing)
        _ = p.handle(F.pointer(at: 1_300))
        XCTAssertTrue(p.buffer.isEmpty)
    }

    // MARK: - (b) app switches

    func testAnAppSwitchAwayAndBackRestoresTheTerminalsBuffer() {
        var p = inTerminal()
        type(&p, [a, s, d])
        p.contextChanged(terminalPID: nil)              // Safari
        XCTAssertTrue(p.buffer.isEmpty, "Safari never sees the terminal's buffer")
        XCTAssertTrue(p.hasParkedBuffer)
        type(&p, [a])                                   // typing in Safari
        p.contextChanged(terminalPID: terminalPID)      // back
        let snap = snapshot(&p)
        XCTAssertEqual(snap?.strokes.count, 3, "the terminal's own three keys, not Safari's")
        XCTAssertEqual(snap?.crossedFocus, true)
        XCTAssertFalse(p.hasParkedBuffer)
    }

    func testAnotherTerminalDropsTheParkedBuffer() {
        var p = inTerminal()
        type(&p, [a, s])
        p.contextChanged(terminalPID: otherTerminalPID)
        XCTAssertFalse(p.hasParkedBuffer)
        p.contextChanged(terminalPID: terminalPID)
        XCTAssertEqual(snapshot(&p)?.hasRun, false)
    }

    func testALanguageChangeWhileAwayKeepsTheBufferInTheLayoutItWasTypedIn() {
        var p = inTerminal()
        type(&p, [a, s])
        p.contextChanged(terminalPID: nil)
        p.inputSourceChanged(to: hebrew, isOurs: false)   // a rule in the other app
        XCTAssertTrue(p.hasParkedBuffer)
        p.contextChanged(terminalPID: terminalPID)
        let snap = snapshot(&p)
        XCTAssertEqual(snap?.strokes.count, 2)
        XCTAssertEqual(snap?.renderedIn, abc, "the screen shows what ABC typed")
    }

    func testSecureInputATapReEnableAndAModeChangeEndTheParkedBuffer() {
        for reason in [ResetReason.secureInputOn, .tapReEnabled, .modeChange] {
            var p = inTerminal()
            type(&p, [a])
            p.contextChanged(terminalPID: nil)
            p.reset(reason)
            XCTAssertFalse(p.hasParkedBuffer, "\(reason)")
            p.contextChanged(terminalPID: terminalPID)
            XCTAssertTrue(p.buffer.isEmpty, "\(reason)")
        }
    }

    // MARK: - (b) what still ends it

    func testReturnKeypadEnterShiftReturnTabAndControlCEndTheLine() {
        let enders: [KeyEvent] = [
            F.key(KeyCode.returnKey),
            F.key(KeyCode.keypadEnter),
            F.key(KeyCode.returnKey, flags: KeyEvent.shiftMask),   // Shift+Return: only the last line converts
            F.key(KeyCode.tab),
            F.key(8, command: true),                               // ⌃C (control counts as a shortcut)
        ]
        for ender in enders {
            var p = inTerminal()
            type(&p, [a, s])
            _ = p.handle(ender)
            XCTAssertTrue(p.buffer.isEmpty, "\(ender.keyCode)")
        }
    }

    func testAfterShiftReturnOnlyTheNewLineIsRemembered() {
        var p = inTerminal()
        type(&p, [a, s])
        _ = p.handle(F.key(KeyCode.returnKey, flags: KeyEvent.shiftMask))
        type(&p, [d])
        XCTAssertEqual(snapshot(&p)?.strokes.count, 1, "never reaches back over a line break")
    }

    func testTheCapStillHolds() {
        var p = inTerminal()
        for i in 0..<(WordBuffer.maxStrokes + 50) {
            _ = p.handle(F.key(i % 7 == 6 ? KeyCode.space : a))
        }
        XCTAssertLessThanOrEqual(p.buffer.keyCount, WordBuffer.maxStrokes)
    }

    // MARK: - (b) the buffer's anchor

    func testATerminalBufferStartSignalsOncePerBufferWithANewEpoch() {
        var p = inTerminal()
        guard case let .terminalBufferStarted(first)? = p.handle(F.key(a)).1 else { return XCTFail("no start") }
        XCTAssertNil(p.handle(F.key(s)).1, "not per key")
        _ = p.handle(F.key(KeyCode.returnKey))
        guard case let .terminalBufferStarted(second)? = p.handle(F.key(a)).1 else { return XCTFail("no start") }
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(snapshot(&p)?.epoch, second)
    }

    func testNoAnchorSignalOutsideATerminal() {
        var p = processor()
        XCTAssertNil(p.handle(F.key(a)).1)
        XCTAssertEqual(snapshot(&p)?.crossedFocus, false)
    }

    func testOurOwnPostsNeverReachTheBuffer() {
        var p = inTerminal()
        _ = p.handle(F.key(ClipboardShortcut.paste.keyCode, origin: .ours, command: true))
        _ = p.handle(F.key(KeyCode.rightArrow, origin: .ours))
        XCTAssertTrue(p.buffer.isEmpty)
    }
}
