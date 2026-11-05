// P2-11: The 19 DoubleShiftDetector cases from R4 (docs/research/keyboard-event-tap.md §2), plus edge cases
// (exact window/hold limits, leftOnly, side restart, lost releases). Times are event timestamps in the inputs.

import XCTest

final class DoubleShiftDetectorTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    private func down(_ side: ShiftSide, _ t: UInt64) -> ShiftInput { .shiftDown(side, atNanos: t * ms) }
    private func up(_ side: ShiftSide, _ t: UInt64) -> ShiftInput { .shiftUp(side, atNanos: t * ms) }

    private func tap(_ side: ShiftSide, _ downMs: UInt64, _ upMs: UInt64) -> [ShiftInput] {
        [down(side, downMs), up(side, upMs)]
    }

    /// Feeds the inputs and returns how many times the detector fired.
    private func fires(_ inputs: [ShiftInput], config: DoubleShiftConfig = .init()) -> Int {
        var detector = DoubleShiftDetector(config: config)
        return inputs.filter { detector.handle($0) }.count
    }

    // MARK: - The 19 R4 cases

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
        let shiftA: [ShiftInput] = [down(.left, 0), .otherKeyDown, up(.left, 80)]
        XCTAssertEqual(fires(shiftA + tap(.left, 150, 200)), 0)
    }

    // 7
    func testTypingBetweenTaps() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [.otherKeyDown] + tap(.left, 150, 200)), 0)
    }

    // 8
    func testCommandBetweenTaps() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [.otherModifierChanged] + tap(.left, 150, 200)), 0)
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
        XCTAssertEqual(fires(tap(.right, 0, 50) + tap(.right, 150, 200), config: config), 1)
    }

    // 12
    func testBothShiftsHeldTogetherIsAChord() {
        let chord: [ShiftInput] = [down(.left, 0), down(.right, 10), up(.left, 50), up(.right, 60)]
        XCTAssertEqual(fires(chord + tap(.left, 100, 150)), 0)
    }

    // 13
    func testTripleTapFiresOnce() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 100, 150) + tap(.left, 200, 250)), 1)
    }

    // 14
    func testQuadrupleTapFiresTwice() {
        let inputs = tap(.left, 0, 50) + tap(.left, 100, 150) + tap(.left, 200, 250) + tap(.left, 300, 350)
        XCTAssertEqual(fires(inputs), 2)
    }

    // 15
    func testSlowTapThenQuickDoubleFiresOnce() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 1000, 1050) + tap(.left, 1100, 1150)), 1)
    }

    // 16
    func testResetMidGesture() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [.reset] + tap(.left, 100, 150)), 0)
    }

    // 17
    func testShiftClick() {
        let shiftClick: [ShiftInput] = [down(.left, 0), .pointerDown, up(.left, 60)]
        XCTAssertEqual(fires(shiftClick + tap(.left, 100, 150)), 0)
    }

    // 18: second press timestamped before the first release (no UInt64 underflow crash).
    func testNonMonotonicTimesAreSafe() {
        XCTAssertEqual(fires(tap(.left, 500, 550) + tap(.left, 100, 150)), 0)
    }

    // 19: a release timestamped before its own press.
    func testReleaseTimedBeforePressIsSafe() {
        XCTAssertEqual(fires(tap(.left, 500, 100)), 0)
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 500, 100)), 0)
    }

    // MARK: - Edges beyond R4 (QA)

    func testGapExactlyAtWindowFires() {
        var detector = DoubleShiftDetector()
        let window = DoubleShiftConfig().windowNanos
        XCTAssertFalse(detector.handle(.shiftDown(.left, atNanos: 0)))
        XCTAssertFalse(detector.handle(.shiftUp(.left, atNanos: 10)))
        XCTAssertFalse(detector.handle(.shiftDown(.left, atNanos: 10 + window)))
        XCTAssertTrue(detector.handle(.shiftUp(.left, atNanos: 20 + window)))
    }

    func testGapOneNanosecondOverWindowDoesNotFire() {
        let window = DoubleShiftConfig().windowNanos
        let inputs: [ShiftInput] = [.shiftDown(.left, atNanos: 0), .shiftUp(.left, atNanos: 10),
                                    .shiftDown(.left, atNanos: 11 + window), .shiftUp(.left, atNanos: 20 + window)]
        XCTAssertEqual(fires(inputs), 0)
    }

    func testHoldsExactlyAtLimitFire() {
        let hold = DoubleShiftConfig().maxHoldNanos
        let inputs: [ShiftInput] = [.shiftDown(.left, atNanos: 0), .shiftUp(.left, atNanos: hold),
                                    .shiftDown(.left, atNanos: hold + 1), .shiftUp(.left, atNanos: 2 * hold + 1)]
        XCTAssertEqual(fires(inputs), 1)
    }

    func testFirstHoldOneNanosecondOverLimitDoesNotFire() {
        let hold = DoubleShiftConfig().maxHoldNanos
        let inputs: [ShiftInput] = [.shiftDown(.left, atNanos: 0), .shiftUp(.left, atNanos: hold + 1),
                                    .shiftDown(.left, atNanos: hold + 2), .shiftUp(.left, atNanos: hold + 3)]
        XCTAssertEqual(fires(inputs), 0)
    }

    func testSecondHoldOneNanosecondOverLimitDoesNotFire() {
        let hold = DoubleShiftConfig().maxHoldNanos
        let inputs: [ShiftInput] = [.shiftDown(.left, atNanos: 0), .shiftUp(.left, atNanos: 1),
                                    .shiftDown(.left, atNanos: 2), .shiftUp(.left, atNanos: hold + 3)]
        XCTAssertEqual(fires(inputs), 0)
    }

    func testCustomWindowIsHonored() {
        let config = DoubleShiftConfig(windowNanos: 500 * ms)
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 450, 500), config: config), 1)
    }

    /// The reason we fire on release: a second press that becomes Shift+letter must not convert.
    func testSecondPressUsedAsModifierDoesNotFire() {
        let inputs = tap(.left, 0, 50) + [down(.left, 100), .otherKeyDown, up(.left, 150)]
        XCTAssertEqual(fires(inputs), 0)
    }

    func testLeftOnlyIgnoresRight() {
        let config = DoubleShiftConfig(sides: .leftOnly)
        XCTAssertEqual(fires(tap(.right, 0, 50) + tap(.right, 150, 200), config: config), 0)
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.left, 150, 200), config: config), 1)
    }

    func testOtherSideRestartsGestureUnderSameSide() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + tap(.right, 100, 150) + tap(.right, 200, 250)), 1)
    }

    func testOtherKeyWhileNoShiftHeldStillCancelsFirstTap() {
        XCTAssertEqual(fires(tap(.left, 0, 50) + [.pointerDown] + tap(.left, 100, 150)), 0)
    }

    func testDuplicateReleaseIsHarmless() {
        XCTAssertEqual(fires([up(.left, 0), up(.right, 5)] + tap(.left, 10, 50) + tap(.left, 100, 150)), 1)
    }

    /// A lost release must not leave the detector stuck: that side's next press heals it.
    func testLostReleaseHealsOnNextPressOfThatSide() {
        // Left goes down, its release is never seen.
        let inputs = [down(.left, 0)] + tap(.left, 1000, 1050) + tap(.left, 1100, 1150)
        XCTAssertEqual(fires(inputs), 1)
    }

    func testResetClearsHeldShifts() {
        let inputs = [down(.left, 0), down(.right, 10), .reset] + tap(.left, 100, 150) + tap(.left, 200, 250)
        XCTAssertEqual(fires(inputs), 1)
    }

    func testFiresAgainAfterAFullCycle() {
        let inputs = tap(.left, 0, 50) + tap(.left, 100, 150) + [.otherKeyDown] + tap(.left, 2000, 2050)
            + tap(.left, 2100, 2150)
        XCTAssertEqual(fires(inputs), 2)
    }
}
