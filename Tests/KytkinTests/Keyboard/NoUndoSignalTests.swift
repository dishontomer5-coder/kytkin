// P3-40 (owner 2026-11-11): a second double-Shift is a fresh convert, not an undo, so the processor no longer tracks
// "untouched since the last convert" (`lastConvertGen` / `untouchedSinceConvert`) or tells main when the field is
// touched after one (`KeySignal.undoTouched`, P3-35 QA). These replace the P3-35 `UndoTouchedTests`: the events that
// used to send `.undoTouched` now give only their ordinary signal, and a kept buffer still reaches the next
// double-Shift whole (the key path's "convert again to the other language"). Pure value tests with a fake clock.

import XCTest

final class NoUndoSignalTests: XCTestCase {
    private typealias F = KeyEventFactory
    private let a: UInt16 = 0, d: UInt16 = 2
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")

    private func processor() -> KeyStreamProcessor {
        var config = KeyProcessorConfig()
        config.mode = .active
        var p = KeyStreamProcessor(config: config, clock: FakeClock())
        p.inputSourceChanged(to: abc, isOurs: false)
        return p
    }

    private func doubleShift(_ p: inout KeyStreamProcessor, at t: UInt64) -> (WordSnapshot, UInt64)? {
        for e in F.doubleShift(at: t) {
            if case let .doubleShift(snap, gen)? = p.handle(e).1 { return (snap, gen) }
        }
        XCTFail("no double-Shift at \(t)")
        return nil
    }

    /// A convert that finished; returns the processor.
    private func converted() -> KeyStreamProcessor {
        var p = processor()
        guard let (_, gen) = doubleShift(&p, at: 500) else { return p }
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: [])
        return p
    }

    func testTheFirstKeyAfterAConvertHasOnlyItsOwnSignal() {
        var p = converted()
        XCTAssertNil(p.handle(F.key(a)).1, "a letter after a convert: no signal (was `.undoTouched`)")
    }

    func testAClickOrATapResetAfterAConvertHasOnlyItsOwnSignal() {
        var click = converted()
        XCTAssertNil(click.handle(F.pointer()).1, "empty buffer: nothing to invalidate")
        var reset = converted()
        XCTAssertNil(reset.handle(KeyEvent(kind: .tapReset)).1)
    }

    func testAKeyHeldBehindTheConvertReplaysWithoutASignal() {
        var p = processor()
        guard let (_, gen) = doubleShift(&p, at: 500) else { return }
        XCTAssertEqual(p.handle(F.key(d)).0, .hold)
        let held = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil)
        XCTAssertEqual(held.count, 1)
        let signals = held.compactMap {
            p.handle(KeyEvent(kind: $0.event.kind, keyCode: $0.event.keyCode, origin: .replay)).1
        }
        XCTAssertEqual(signals, [])
    }

    /// The key path (X5): a buffer kept and re-rendered by the first convert reaches the second double-Shift whole, in
    /// the layout it shows in now, so the controller converts it to the other language again.
    func testAKeptBufferReachesTheSecondDoubleShiftWhole() {
        var p = processor()
        _ = p.handle(F.key(a))
        _ = p.handle(F.key(d))
        guard let (first, gen) = doubleShift(&p, at: 500) else { return }
        XCTAssertEqual(first.renderedIn, abc)
        _ = p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil, bufferRenderedIn: hebrew)
        guard let (second, _) = doubleShift(&p, at: 2_000) else { return }
        XCTAssertEqual(second.strokes, first.strokes)
        XCTAssertEqual(second.renderedIn, hebrew, "converts from the layout it shows in now")
    }
}
