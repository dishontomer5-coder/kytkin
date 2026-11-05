// P2-11: The 19 DoubleShiftDetector cases from R4 (docs/research/keyboard-event-tap.md §2), driven by FakeClock.

import XCTest

final class DoubleShiftDetectorTests: XCTestCase {
    /// One input at a time in milliseconds. `nil` time = the input doesn't read the clock (e.g. reset).
    private typealias Step = (ms: UInt64?, input: ShiftInput)

    private func tap(_ side: ShiftSide, _ downMs: UInt64, _ upMs: UInt64) -> [Step] {
        [(downMs, .shiftDown(side)), (upMs, .shiftUp(side))]
    }

    /// Feeds the steps with a monotonic FakeClock and returns how many times the detector fired.
    private func fires(_ steps: [Step], config: DoubleShiftConfig = .init()) -> Int {
        let clock = FakeClock()
        var detector = DoubleShiftDetector(config: config, clock: clock)
        var count = 0
        for step in steps {
            if let ms = step.ms { clock.set(nowNanos: ms * 1_000_000) }
            if detector.handle(step.input) { count += 1 }
        }
        return count
    }

    /// Same, but with a clock that may go backwards (FakeClock forbids that), for the underflow guards.
    private func firesWithUnorderedTimes(_ steps: [Step]) -> Int {
        let clock = SettableClock()
        var detector = DoubleShiftDetector(clock: clock)
        var count = 0
        for step in steps {
            if let ms = step.ms { clock.nowNanos = ms * 1_000_000 }
            if detector.handle(step.input) { count += 1 }
        }
        return count
    }

    // 1
    func testBasicDoubleLeft() {
        XCTAssertEqual(fires(tap(.left, 0, 60) + tap(.left, 200, 260)), 1)
    }

    // 2
    func testBasicDoubleRight() {
        XCTAssertEqual(fires(tap(.right, 0, 60) + tap(.right, 200, 260)), 1)
    }

    // 3
    func testGapTooLong() {
        XCTAssertEqual(fires(tap(.left, 0, 60) + tap(.left, 400, 460)), 0)
    }

    // 4
    func testFirstTapHeldTooLong() {
        XCTAssertEqual(fires(tap(.left, 0, 400) + tap(.left, 450, 500)), 0)
    }

    // 5
    func testSecondTapHeldTooLong() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 100, 500)), 0)
    }

    // 6
    func testShiftAsModifierThenTap() {
        let shiftA: [Step] = [(0, .shiftDown(.left)), (30, .otherKeyDown), (80, .shiftUp(.left))]
        XCTAssertEqual(fires(shiftA + tap(.left, 150, 200)), 0)
    }

    // 7
    func testTypingBetweenTaps() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [(100, .otherKeyDown)] + tap(.left, 150, 200)), 0)
    }

    // 8
    func testCommandBetweenTaps() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [(100, .otherModifierChanged)] + tap(.left, 150, 200)), 0)
    }

    // 9
    func testMixedSidesUnderSameSidePolicy() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.right, 150, 200)), 0)
    }

    // 10
    func testMixedSidesUnderEitherPolicy() {
        let config = DoubleShiftConfig(sides: .either)
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.right, 150, 200), config: config), 1)
    }

    // 11
    func testRightOnlyIgnoresLeft() {
        let config = DoubleShiftConfig(sides: .rightOnly)
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 150, 200), config: config), 0)
    }

    // 12
    func testBothShiftsHeldTogetherIsAChord() {
        let chord: [Step] = [(0, .shiftDown(.left)), (10, .shiftDown(.right)),
                             (50, .shiftUp(.left)), (60, .shiftUp(.right))]
        XCTAssertEqual(fires(chord + tap(.left, 100, 150)), 0)
    }

    // 13
    func testTripleTapFiresOnce() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 100, 150) + tap(.left, 200, 250)), 1)
    }

    // 14
    func testQuadrupleTapFiresTwice() {
        let steps = tap(.left, 0, 50) + tap(.left, 100, 150) + tap(.left, 200, 250) + tap(.left, 300, 350)
        XCTAssertEqual(fires(steps), 2)
    }

    // 15
    func testSlowTapThenQuickDoubleFiresOnce() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 1000, 1050) + tap(.left, 1100, 1150)), 1)
    }

    // 16
    func testResetMidGesture() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [(nil, .reset)] + tap(.left, 100, 150)), 0)
    }

    // 17
    func testShiftClick() {
        let shiftClick: [Step] = [(0, .shiftDown(.left)), (20, .pointerDown), (60, .shiftUp(.left))]
        XCTAssertEqual(fires(shiftClick + tap(.left, 100, 150)), 0)
    }

    // 18
    func testNonMonotonicTimesAreSafe() {
        XCTAssertEqual(firesWithUnorderedTimes(tap(.left, 500, 550) + tap(.left, 100, 150)), 0)
    }

    // 19
    func testReleaseTimedBeforePressIsSafe() {
        XCTAssertEqual(firesWithUnorderedTimes(tap(.left, 500, 100)), 0)
    }
}

/// P2-11: A clock that can move backwards, standing in for out-of-order event timestamps.
private final class SettableClock: Clock, @unchecked Sendable { // @unchecked: single-threaded test use only
    var nowNanos: UInt64 = 0
}
