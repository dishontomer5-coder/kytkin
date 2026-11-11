// P3-35 QA (owner, 2026-11-11): the undo record has no timer; the processor tells main when the field is touched after
// a convert (`KeySignal.undoTouched`): the first user key, click or tap reset after a convert finished, once per
// convert. Pure value tests with a fake clock; nothing is installed or posted.

import XCTest

final class UndoTouchedTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, d: UInt16 = 2
    private let abc = InputSourceID("com.apple.keylayout.ABC")

    private func processor() -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.mode = .active
        var p = KeyStreamProcessor(config: config, clock: FakeClock())
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    private func doubleShift(_ p: inout KeyStreamProcessor, at t: UInt64) -> UInt64? {
        for e in F.doubleShift(at: t) {
            if case let .doubleShift(_, gen)? = p.handle(e).1 { return gen }
        }
        XCTFail("no double-Shift at \(t)")
        return nil
    }

    /// A convert that finished; returns the processor.
    private func converted() -> KeyStreamProcessor {
        var p = processor()
        guard let gen = doubleShift(&p, at: 500) else { return p }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: [])
        return p
    }

    func testNoSignalWithoutAConvert() {
        var p = processor()
        XCTAssertNotEqual(p.handle(F.key(a)).1, .undoTouched)
        XCTAssertNotEqual(p.handle(F.pointer()).1, .undoTouched)
        XCTAssertFalse(p.undoMayBeHeld)
    }

    func testTheFirstKeyAfterAConvertSignalsOnce() {
        var p = converted()
        XCTAssertTrue(p.undoMayBeHeld)
        XCTAssertEqual(p.handle(F.key(a)).1, .undoTouched)
        XCTAssertFalse(p.undoMayBeHeld)
        XCTAssertNotEqual(p.handle(F.key(d)).1, .undoTouched, "once per convert")
    }

    func testAClickOrATapResetAfterAConvertSignals() {
        var click = converted()
        let s = click.handle(F.pointer()).1
        XCTAssertTrue(s == .undoTouched || s == .bufferInvalidated, "main drops the undo on either")
        XCTAssertFalse(click.undoMayBeHeld)
        var reset = converted()
        let r = reset.handle(KeyEvent(kind: .tapReset)).1
        XCTAssertTrue(r == .undoTouched || r == .bufferInvalidated)
        XCTAssertFalse(reset.undoMayBeHeld)
    }

    func testKeyUpsFlagsAndOurOwnPostsDoNotCount() {
        var p = converted()
        XCTAssertNotEqual(p.handle(F.keyUp(a)).1, .undoTouched)
        XCTAssertNotEqual(p.handle(F.key(a, origin: .ours)).1, .undoTouched, "Kytkin's own typing")
        XCTAssertTrue(p.undoMayBeHeld)
        XCTAssertEqual(p.handle(F.key(a)).1, .undoTouched)
    }

    func testAnAbortedConvertStillSignalsOnTheNextKey() {
        // A click during the convert aborts it; the controller may still finish and keep a record.
        var p = processor()
        guard let gen = doubleShift(&p, at: 500) else { return }
        _ = p.handle(F.pointer(at: 600))
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
        XCTAssertTrue(p.undoMayBeHeld)
        XCTAssertEqual(p.handle(F.key(a)).1, .undoTouched)
    }

    func testAKeyHeldBehindTheConvertSignalsOnItsReplay() {
        var p = processor()
        guard let gen = doubleShift(&p, at: 500) else { return }
        XCTAssertEqual(p.handle(F.key(d)).0, .hold)
        let held = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
        XCTAssertEqual(held.count, 1)
        let signals = held.compactMap {
            p.handle(KeyEvent(kind: $0.event.kind, keyCode: $0.event.keyCode, origin: .replay)).1
        }
        XCTAssertEqual(signals, [.undoTouched], "the replayed key typed after the convert")
    }

    func testTheNextDoubleShiftIsNotATouch() {
        var p = converted()
        var signals: [KeySignal] = []
        for e in F.doubleShift(at: 2_000) { if let s = p.handle(e).1 { signals.append(s) } }
        XCTAssertFalse(signals.contains(.undoTouched), "the undo itself must find its record")
    }
}
