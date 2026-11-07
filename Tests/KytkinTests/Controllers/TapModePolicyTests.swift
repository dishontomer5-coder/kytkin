// P2-20 / P2-46: TapModePolicy (001 §12 W7): start only when the desired mode changed, or when it is below the
// desired one and a grant changed; never otherwise.

import XCTest

final class TapModePolicyTests: XCTestCase {
    func testFirstDecisionStartsTheDesiredMode() {
        var p = TapModePolicy()
        XCTAssertEqual(p.decide(desired: .active, grantsChanged: false), .start(.active))
    }

    func testFirstDecisionOffDoesNothing() {
        var p = TapModePolicy()
        XCTAssertNil(p.decide(desired: .off, grantsChanged: true))
        XCTAssertNil(p.decide(desired: .off, grantsChanged: true))
    }

    func testSameDesiredModeNeverRestarts() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        XCTAssertNil(p.decide(desired: .active, grantsChanged: false))
        XCTAssertNil(p.decide(desired: .active, grantsChanged: true), "already running at the desired mode")
    }

    func testDesiredChangeStarts() {
        var p = TapModePolicy()
        _ = p.decide(desired: .listenOnly, grantsChanged: false)
        p.started(achieved: .listenOnly)
        XCTAssertEqual(p.decide(desired: .active, grantsChanged: true), .start(.active))
    }

    func testDesiredOffStopsARunningTap() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        XCTAssertEqual(p.decide(desired: .off, grantsChanged: false), .stop)
        p.stopped()
        XCTAssertEqual(p.achieved, .off)
        XCTAssertNil(p.decide(desired: .off, grantsChanged: true))
    }

    func testDesiredOffStopsAThreadEvenIfTheStartFailed() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .off)
        XCTAssertEqual(p.decide(desired: .off, grantsChanged: false), .stop)
    }

    func testBelowDesiredRetriesOnlyOnAGrantChange() {
        var p = TapModePolicy()
        _ = p.decide(desired: .listenOnly, grantsChanged: false)
        p.started(achieved: .off)   // e.g. Input Monitoring needs a relaunch, or a start timeout
        XCTAssertNil(p.decide(desired: .listenOnly, grantsChanged: false), "no retry on settings/status/timer")
        XCTAssertEqual(p.decide(desired: .listenOnly, grantsChanged: true), .start(.listenOnly))
    }

    func testWatchdogDowngradeIsNotRetriedUntilAGrantChanges() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        p.statusReported(mode: .listenOnly)
        XCTAssertNil(p.decide(desired: .active, grantsChanged: false))
        XCTAssertEqual(p.decide(desired: .active, grantsChanged: true), .start(.active))
    }

    func testQuitAndReopenOnlyWhileBelowDesiredAndRelaunchNeeded() {
        var p = TapModePolicy()
        XCTAssertFalse(p.showsQuitAndReopen(needsRelaunch: true), "nothing requested yet")
        _ = p.decide(desired: .listenOnly, grantsChanged: false)
        p.started(achieved: .off)
        XCTAssertTrue(p.showsQuitAndReopen(needsRelaunch: true))
        XCTAssertFalse(p.showsQuitAndReopen(needsRelaunch: false))
        p.started(achieved: .listenOnly)
        XCTAssertFalse(p.showsQuitAndReopen(needsRelaunch: true))
    }

    // MARK: - P2-22: "Restart Keyboard Features"

    func testRestartOnlyWhenBelowTheDesiredMode() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        XCTAssertNil(p.restartAction(desired: .active), "already running")
        p.statusReported(mode: .listenOnly)      // the watchdog lowered it
        XCTAssertEqual(p.restartAction(desired: .active), .start(.active))
        p.statusReported(mode: .off)
        XCTAssertEqual(p.restartAction(desired: .listenOnly), .start(.listenOnly))
        XCTAssertNil(p.restartAction(desired: .off), "nothing wants a tap")
    }

    func testRestartIsRecordedSoDecideDoesNotRepeatIt() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        p.statusReported(mode: .listenOnly)
        p.restarting(.active)
        p.started(achieved: .active)
        XCTAssertNil(p.decide(desired: .active, grantsChanged: false))
        XCTAssertNil(p.restartAction(desired: .active))
    }
}
