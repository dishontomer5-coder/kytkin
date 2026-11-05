// P2-12: Tap watchdog policy (001 §7 B4): 3 disables in 60 s → listen-only, 3 more → off.

import XCTest

final class TapHealthPolicyTests: XCTestCase {
    private let sec: UInt64 = 1_000_000_000

    func testFewDisablesJustReEnable() {
        var p = TapHealthPolicy()
        XCTAssertEqual(p.tapWasDisabled(atNanos: 0, mode: .active), .reEnable)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 10 * sec, mode: .active), .reEnable)
    }

    func testThirdDisableIn60sDropsToListenOnlyThenOff() {
        var p = TapHealthPolicy()
        XCTAssertEqual(p.tapWasDisabled(atNanos: 0, mode: .active), .reEnable)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 5 * sec, mode: .active), .reEnable)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 10 * sec, mode: .active), .downgradeToListenOnly)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 11 * sec, mode: .listenOnly), .reEnable)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 12 * sec, mode: .listenOnly), .reEnable)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 13 * sec, mode: .listenOnly), .turnOff)
    }

    func testDisablesSpreadOverMoreThan60sNeverDowngrade() {
        var p = TapHealthPolicy()
        for i: UInt64 in 0..<20 {
            XCTAssertEqual(p.tapWasDisabled(atNanos: i * 31 * sec, mode: .active), .reEnable)
        }
    }

    func testWindowEdgeIsExclusive() {
        var p = TapHealthPolicy()
        _ = p.tapWasDisabled(atNanos: 0, mode: .active)
        _ = p.tapWasDisabled(atNanos: 30 * sec, mode: .active)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 60 * sec, mode: .active), .reEnable, "the first one aged out")
        XCTAssertEqual(p.tapWasDisabled(atNanos: 61 * sec, mode: .active), .downgradeToListenOnly)
    }

    func testOffStaysOff() {
        var p = TapHealthPolicy()
        XCTAssertEqual(p.tapWasDisabled(atNanos: 0, mode: .off), .turnOff)
    }

    func testBackwardsTimestampsDontCrash() {
        var p = TapHealthPolicy()
        _ = p.tapWasDisabled(atNanos: 100 * sec, mode: .active)
        XCTAssertEqual(p.tapWasDisabled(atNanos: 1 * sec, mode: .active), .reEnable)
    }

    func testResetClearsTheCount() {
        var p = TapHealthPolicy()
        _ = p.tapWasDisabled(atNanos: 0, mode: .active)
        _ = p.tapWasDisabled(atNanos: 1 * sec, mode: .active)
        p.reset()
        XCTAssertEqual(p.tapWasDisabled(atNanos: 2 * sec, mode: .active), .reEnable)
    }

    func testTapHealthCountsOverBudgetCallbacks() {
        var h = TapHealth()
        h.recordCallback(durationNanos: 50_000)
        h.recordCallback(durationNanos: 1_000_000)
        h.recordCallback(durationNanos: 1_000_001)
        XCTAssertEqual(h.overBudgetCallbacks, 1)
    }
}
