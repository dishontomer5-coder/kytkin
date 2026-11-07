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

    // MARK: - P2-52 item 2 / P2-57 item 1: one retry after a launch timeout, never silent

    func testLaunchTimeoutArmsExactlyOneActivationRetry() {
        var p = TapModePolicy()
        XCTAssertEqual(p.decide(desired: .active, grantsChanged: false), .start(.active))
        p.started(achieved: .off)                           // timed out on a busy system
        XCTAssertTrue(p.runsBelow(desired: .active))
        XCTAssertEqual(p.activationRetry(desired: .active), .start(.active))
        XCTAssertNil(p.activationRetry(desired: .active), "used up when returned")
        p.started(achieved: .off)                           // the retry failed too
        XCTAssertTrue(p.runsBelow(desired: .active), "still below: the warning stays")
        for _ in 0..<200 {
            XCTAssertNil(p.activationRetry(desired: .active))
            XCTAssertNil(p.decide(desired: .active, grantsChanged: false))
        }
        XCTAssertEqual(p.restartAction(desired: .active), .start(.active), "the user can still restart")
    }

    func testASuccessfulFirstStartArmsNoRetry() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .active)
        XCTAssertFalse(p.runsBelow(desired: .active))
        p.statusReported(mode: .listenOnly)                 // a later watchdog downgrade is not a launch timeout
        XCTAssertNil(p.activationRetry(desired: .active))
        XCTAssertTrue(p.runsBelow(desired: .active))
    }

    func testAnyLaterStartUsesUpTheRetry() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .off)
        XCTAssertEqual(p.decide(desired: .active, grantsChanged: true), .start(.active))   // a grant changed
        p.started(achieved: .off)
        XCTAssertNil(p.activationRetry(desired: .active), "no second automatic start right after the first")
    }

    func testRetryOnlyForTheModeStillWantedAndStillMissing() {
        var p = TapModePolicy()
        _ = p.decide(desired: .active, grantsChanged: false)
        p.started(achieved: .off)
        XCTAssertNil(p.activationRetry(desired: .off), "paused / turned off since")
        p.statusReported(mode: .active)                     // the late apply came through after all
        XCTAssertNil(p.activationRetry(desired: .active))
        XCTAssertFalse(p.runsBelow(desired: .active))
    }

    func testRunsBelowNeedsSomethingRequestedAndWanted() {
        var p = TapModePolicy()
        XCTAssertFalse(p.runsBelow(desired: .active), "nothing decided yet")
        _ = p.decide(desired: .listenOnly, grantsChanged: false)
        p.started(achieved: .off)
        XCTAssertFalse(p.runsBelow(desired: .off))
        XCTAssertTrue(p.runsBelow(desired: .listenOnly))
    }
}
