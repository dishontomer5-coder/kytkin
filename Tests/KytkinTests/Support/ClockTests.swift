// P2-4: Tests for SystemClock and the FakeClock test helper.

import XCTest

final class ClockTests: XCTestCase {
    func testSystemClockIsMonotonic() {
        let clock: any Clock = SystemClock()
        var previous = clock.nowNanos
        for _ in 0..<1_000 {
            let now = clock.nowNanos
            XCTAssertGreaterThanOrEqual(now, previous)
            previous = now
        }
    }

    func testSystemClockAdvancesInNanoseconds() {
        let clock = SystemClock()
        let start = clock.nowNanos
        Thread.sleep(forTimeInterval: 0.02)
        let elapsed = clock.nowNanos - start
        XCTAssertGreaterThanOrEqual(elapsed, 15_000_000) // ≥ 15 ms after sleeping 20 ms
        XCTAssertLessThan(elapsed, 5_000_000_000)        // and not wildly off (< 5 s)
    }

    func testFakeClockStartsWhereToldAndOnlyMovesWhenAdvanced() {
        let clock = FakeClock(nowNanos: 42)
        XCTAssertEqual(clock.nowNanos, 42)
        XCTAssertEqual(clock.nowNanos, 42)
        clock.advance(byNanos: 8)
        XCTAssertEqual(clock.nowNanos, 50)
    }

    func testFakeClockUnitHelpers() {
        let clock = FakeClock()
        clock.advance(byMilliseconds: 150)
        XCTAssertEqual(clock.nowNanos, 150_000_000)
        clock.advance(bySeconds: 2)
        XCTAssertEqual(clock.nowNanos, 2_150_000_000)
        clock.set(nowNanos: 3_000_000_000)
        XCTAssertEqual(clock.nowNanos, 3_000_000_000)
    }

    func testFakeClockWorksThroughTheProtocol() {
        let fake = FakeClock()
        let clock: any Clock = fake
        fake.advance(byMilliseconds: 1)
        XCTAssertEqual(clock.nowNanos, 1_000_000)
    }
}
