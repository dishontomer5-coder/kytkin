// P3-10: The real AX thread and its run-loop timer (001 §14.1). No AX calls here: only blocks and a timer.

import ApplicationServices
import XCTest

final class AXThreadTests: XCTestCase {
    final class Box: @unchecked Sendable { // @unchecked: guarded by `lock`
        private let lock = NSLock()
        private var _items: [String] = []
        var items: [String] { lock.withLock { _items } }
        func append(_ s: String) { lock.withLock { _items.append(s) } }
    }

    func testBlocksRunInOrderOnTheNamedThreadEvenIfSentBeforeItStarts() {
        let thread = AXThread()
        let box = Box()
        let done = expectation(description: "ran")
        thread.async { box.append("1:\(Thread.current.name ?? "")") }
        thread.async { box.append("2") }
        thread.start()
        thread.async { box.append("3") }
        thread.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(box.items, ["1:io.github.kytkin.ax", "2", "3"])
        thread.stopRunLoop()
    }

    func testDeadlineTimerFiresOnTheAXThreadAndCanBeRemoved() {
        let thread = AXThread()
        thread.start()
        let fired = expectation(description: "fired")
        let notFired = expectation(description: "removed timer never fires")
        notFired.isInverted = true
        let clock = SystemClock()
        let box = Box()
        nonisolated(unsafe) var keep: [RunLoopDeadlineTimer] = []
        thread.async {
            let t1 = RunLoopDeadlineTimer(clock: clock)
            t1.onFire = {
                box.append(Thread.current.name ?? "")
                fired.fulfill()
            }
            t1.schedule(atNanos: clock.nowNanos + 20_000_000)
            let t2 = RunLoopDeadlineTimer(clock: clock)
            t2.onFire = { notFired.fulfill() }
            t2.schedule(atNanos: clock.nowNanos + 20_000_000)
            t2.schedule(atNanos: nil)
            keep = [t1, t2]
        }
        wait(for: [fired, notFired], timeout: 0.5)
        XCTAssertEqual(box.items, ["io.github.kytkin.ax"])
        let cleaned = expectation(description: "cleaned")
        thread.async {
            keep = []
            cleaned.fulfill()
        }
        wait(for: [cleaned], timeout: 1)
        thread.stopRunLoop()
    }

    func testAXErrorMapping() {
        XCTAssertEqual(AXReadError(.cannotComplete), .timedOut, "a messaging timeout trips the read's latch")
        XCTAssertEqual(AXReadError(.invalidUIElement), .invalidElement)
        XCTAssertEqual(AXReadError(.apiDisabled), .apiDisabled)
        XCTAssertEqual(AXReadError(.failure), .other)
        XCTAssertEqual(AXReadError(.notificationUnsupported), .other)
    }
}
