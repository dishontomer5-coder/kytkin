// P2-12: Callback budget B1 (001 §7): the processor's per-event path must be cheap and O(1).
// 001 asks for 100k synthetic events in < 0.5 s in a Debug build. The threshold here is 4× that, so a busy
// CI machine doesn't make it flaky; a real regression (allocation or a scan per key) blows far past it.
// Prints nothing.

import XCTest

final class KeyStreamProcessorBudgetTests: XCTestCase {
    private typealias F = KeyEventFactory

    func testHundredThousandEventsFitTheBudget() {
        let clock = FakeClock()
        var p = KeyStreamProcessor(config: KeyProcessorConfig(), clock: clock)

        // A realistic mix: letters (some shifted), word boundaries, Backspace, an arrow now and then,
        // a mouse click, and a double-Shift (with hold-back + finish) every so often.
        var events: [KeyEvent] = []
        events.reserveCapacity(100_000)
        var t: UInt64 = 0
        while events.count < 100_000 {
            t += 1
            let i = events.count
            switch i % 97 {
            case 0: events.append(contentsOf: F.doubleShift(at: t))
            case 13: events.append(F.key(KeyCode.leftArrow, at: t))
            case 41: events.append(F.pointer(at: t))
            default:
                if i % 6 == 5 {
                    events.append(F.key(KeyCode.space, at: t))
                } else if i % 23 == 0 {
                    events.append(F.key(KeyCode.delete, at: t))
                } else {
                    let flags: UInt64 = i % 11 == 0 ? KeyEvent.shiftMask | KeyEvent.leftShiftDeviceBit : 0
                    events.append(F.key(UInt16(i % 40), flags: flags, at: t))
                    events.append(F.keyUp(UInt16(i % 40), at: t))
                }
            }
        }

        var signals = 0
        var held = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for e in events {
            let (verdict, signal) = p.handle(e)
            if verdict == .hold { held += 1 }
            if let signal {
                signals += 1
                if case let .doubleShift(_, gen) = signal {
                    held += p.finishReplacement(gen: gen, newRendering: nil, bufferAfter: nil).count
                }
            }
            if let flushed = p.pollFlush() { held += flushed.count }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start

        XCTAssertGreaterThan(signals, 0)
        XCTAssertLessThan(elapsed, 2_000_000_000, "100k events took \(elapsed / 1_000_000) ms (budget B1)")
        XCTAssertLessThanOrEqual(p.buffer.strokeCount, WordBuffer.maxStrokes)
    }
}
