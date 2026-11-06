// P2-19: Pure ConflictDetector logic: preference mapping, switcher diffing, change detection, fights.

import XCTest

final class PerDocumentInputPrefTests: XCTestCase {
    private let key = PerDocumentInputPref.flagKey

    func testAbsentDictionaryIsOff() {
        // What this Mac has (2026-11-06): no AppleGlobalTextInputProperties at all.
        XCTAssertFalse(PerDocumentInputPref.isEnabled(nil))
        XCTAssertFalse(PerDocumentInputPref.isEnabled(hiToolbox: nil, global: nil))
    }

    func testExpectedOnFormIsOn() {
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: 1]))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: true]))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: NSNumber(value: 1)] as NSDictionary))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: NSNumber(value: true)] as NSDictionary))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: "1"]))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: " YES "]))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: 2]))
    }

    func testExplicitOffAndJunkAreOff() {
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: 0]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: false]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: "0"]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: "maybe"]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: [1]]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([String: Any]()))               // dictionary without the flag
        XCTAssertFalse(PerDocumentInputPref.isEnabled(["SomethingElse": 1]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled(1))                             // not a dictionary
        XCTAssertFalse(PerDocumentInputPref.isEnabled("TextInputGlobalPropertyPerContextInput"))
    }

    func testEitherDomainOnCounts() {
        XCTAssertTrue(PerDocumentInputPref.isEnabled(hiToolbox: [key: 1], global: nil))
        XCTAssertTrue(PerDocumentInputPref.isEnabled(hiToolbox: nil, global: [key: 1]))
        XCTAssertTrue(PerDocumentInputPref.isEnabled(hiToolbox: [key: 0], global: [key: 1]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled(hiToolbox: [key: 0], global: [key: 0]))
    }

    func testKeyNames() {
        XCTAssertEqual(PerDocumentInputPref.domain, "com.apple.HIToolbox")
        XCTAssertEqual(PerDocumentInputPref.dictionaryKey, "AppleGlobalTextInputProperties")
        XCTAssertEqual(PerDocumentInputPref.flagKey, "TextInputGlobalPropertyPerContextInput")
    }
}

final class ConflictsTests: XCTestCase {
    func testEmptyAndPause() {
        XCTAssertTrue(Conflicts.none.isEmpty)
        XCTAssertFalse(Conflicts.none.pausesLearning)
        let switcher = Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: false)
        XCTAssertFalse(switcher.isEmpty)
        XCTAssertFalse(switcher.pausesLearning, "another switcher warns but doesn't pause learning")
        let perDoc = Conflicts(runningSwitchers: [], perDocumentInputEnabled: true)
        XCTAssertFalse(perDoc.isEmpty)
        XCTAssertTrue(perDoc.pausesLearning, "P2-38")
    }
}

final class ConflictStateTests: XCTestCase {
    private func app(_ pid: Int32, _ bundleID: String?, _ name: String?) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundleID: bundleID, name: name)
    }

    private let flicKey = RunningAppInfo(pid: 50, bundleID: "com.talalfi.FlicKey", name: "FlicKey")
    private let safari = RunningAppInfo(pid: 10, bundleID: "com.apple.Safari", name: "Safari")

    func testLaunchScanFindsSwitchersInEntriesOrder() {
        var s = ConflictState()
        let out = s.apply(.scan([safari, app(60, nil, "Kawa"), flicKey]))
        XCTAssertEqual(out?.runningSwitchers, ["FlicKey", "Kawa"])
        XCTAssertEqual(s.conflicts.runningSwitchers, ["FlicKey", "Kawa"])
    }

    func testScanWithNothingReportsNoChange() {
        var s = ConflictState()
        XCTAssertNil(s.apply(.scan([safari])))
        XCTAssertNil(s.apply(.scan([])))
        XCTAssertEqual(s.conflicts, .none)
    }

    func testLaunchAndTerminateDiff() {
        var s = ConflictState()
        s.apply(.scan([safari]))
        XCTAssertEqual(s.apply(.launched(flicKey))?.runningSwitchers, ["FlicKey"])
        XCTAssertNil(s.apply(.launched(flicKey)), "duplicate launch notification")
        XCTAssertNil(s.apply(.launched(app(11, "com.apple.TextEdit", "TextEdit"))))
        XCTAssertNil(s.apply(.terminated(pid: 11)))
        XCTAssertEqual(s.apply(.terminated(pid: 50))?.runningSwitchers, [])
        XCTAssertNil(s.apply(.terminated(pid: 50)), "duplicate terminate")
    }

    func testTwoCopiesCountOnceAndStayUntilBothQuit() {
        var s = ConflictState()
        s.apply(.launched(flicKey))
        XCTAssertNil(s.apply(.launched(app(51, "com.talalfi.FlicKey", "FlicKey"))))
        XCTAssertEqual(s.conflicts.runningSwitchers, ["FlicKey"])
        XCTAssertNil(s.apply(.terminated(pid: 50)))
        XCTAssertEqual(s.apply(.terminated(pid: 51))?.runningSwitchers, [])
    }

    func testRescanHealsAMissedTerminate() {
        var s = ConflictState()
        s.apply(.launched(flicKey))
        XCTAssertEqual(s.apply(.scan([safari]))?.runningSwitchers, [])
    }

    func testReusedPIDThatIsNotASwitcherClearsIt() {
        var s = ConflictState()
        s.apply(.launched(flicKey))
        XCTAssertEqual(s.apply(.launched(app(50, "com.apple.TextEdit", "TextEdit")))?.runningSwitchers, [])
    }

    func testKytkinItselfNeverCounts() {
        var s = ConflictState()
        XCTAssertNil(s.apply(.launched(app(7, "io.github.kytkin.Kytkin.dev", "Kytkin Dev"))))
        XCTAssertNil(s.apply(.launched(app(8, "io.github.kytkin.Kytkin", "Kytkin"))))
    }

    func testPerDocumentInputChangeDetection() {
        var s = ConflictState()
        XCTAssertNil(s.apply(.perDocumentInput(false)), "off is the starting state")
        let on = s.apply(.perDocumentInput(true))
        XCTAssertEqual(on, Conflicts(runningSwitchers: [], perDocumentInputEnabled: true))
        XCTAssertTrue(on?.pausesLearning ?? false)
        XCTAssertNil(s.apply(.perDocumentInput(true)), "a re-read with the same value reports nothing")
        XCTAssertEqual(s.apply(.perDocumentInput(false))?.pausesLearning, false)
    }

    func testBothConflictsTogether() {
        var s = ConflictState()
        s.apply(.perDocumentInput(true))
        let out = s.apply(.launched(flicKey))
        XCTAssertEqual(out, Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: true))
        XCTAssertNil(s.apply(.scan([flicKey])), "a rescan with the same apps keeps the per-document flag")
    }

    func testCustomEntries() {
        let entries = [KnownSwitcher(name: "Test Switcher", bundleIDs: ["com.example.switch"], nameContains: "Switchy")]
        var s = ConflictState(entries: entries)
        XCTAssertNil(s.apply(.launched(flicKey)), "only the given entries count")
        XCTAssertEqual(s.apply(.launched(app(3, "COM.EXAMPLE.SWITCH", nil)))?.runningSwitchers, ["Test Switcher"])
    }
}

final class FightCounterTests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testExternalSoonAfterOursCountsOnce() {
        var f = FightCounter()
        f.ourSwitch(atNanos: 1_000 * ms)
        XCTAssertTrue(f.externalSwitch(atNanos: 1_200 * ms))
        XCTAssertFalse(f.externalSwitch(atNanos: 1_250 * ms), "one of our switches counts at most once")
        XCTAssertEqual(f.count, 1)
    }

    func testWindowEdge() {
        var f = FightCounter()
        f.ourSwitch(atNanos: 1_000 * ms)
        XCTAssertFalse(f.externalSwitch(atNanos: 1_300 * ms), "exactly 300 ms is not < 300 ms")
        f.ourSwitch(atNanos: 2_000 * ms)
        XCTAssertTrue(f.externalSwitch(atNanos: 2_299 * ms))
        XCTAssertEqual(f.count, 1)
    }

    func testNoOwnSwitchOrOutOfOrderIsNoFight() {
        var f = FightCounter()
        XCTAssertFalse(f.externalSwitch(atNanos: 5 * ms))
        f.ourSwitch(atNanos: 1_000 * ms)
        XCTAssertFalse(f.externalSwitch(atNanos: 900 * ms), "before ours")
        XCTAssertEqual(f.count, 0)
    }

    func testRepeatedFightsAccumulateAndReset() {
        var f = FightCounter()
        for i: UInt64 in 1...3 {
            f.ourSwitch(atNanos: i * 1_000 * ms)
            f.externalSwitch(atNanos: i * 1_000 * ms + 50 * ms)
        }
        XCTAssertEqual(f.count, 3)
        f.reset()
        XCTAssertEqual(f.count, 0)
        XCTAssertFalse(f.externalSwitch(atNanos: 3_100 * ms), "reset forgets the last switch")
    }
}
