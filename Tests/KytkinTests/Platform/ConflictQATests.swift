// P2-19 QA: edge cases the builder's tests didn't pin down: lenient mapping never says "on" by mistake,
// pid reuse between switchers, Kytkin's own bundle IDs beating a switcher-like name, fight-counter edges,
// and refresh() staying quiet when nothing changed. Pure / fake-driven; no app or preference is touched.

import AppKit
import XCTest

final class PerDocumentInputPrefQATests: XCTestCase {
    private let key = PerDocumentInputPref.flagKey

    func testNonBooleanishValuesNeverMeanOn() {
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: NSNull()]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: Date()]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: Data([1])]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: [key: 1]]))           // nested dictionary
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: ""]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: "no"]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: "off"]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: NSNumber(value: 0.0)]))
    }

    func testFlagOnlyCountsInsideTheDictionary() {
        // A flag one level up (a top-level key, or the legacy TSM-prefixed name) is not what the reader reads.
        XCTAssertFalse(PerDocumentInputPref.isEnabled(["TSMTextInputGlobalPropertyPerContextInput": 1]))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key.lowercased(): 1]), "keys are case-sensitive")
    }

    func testCFBooleanAndStringFormsFromCFPreferences() {
        // What CFPreferencesCopyAppValue hands back for a plist <true/> / <integer>1</integer> / "TRUE".
        let fromPlist = [key: kCFBooleanTrue!] as NSDictionary
        XCTAssertTrue(PerDocumentInputPref.isEnabled(fromPlist))
        XCTAssertFalse(PerDocumentInputPref.isEnabled([key: kCFBooleanFalse!] as NSDictionary))
        XCTAssertTrue(PerDocumentInputPref.isEnabled([key: "TRUE"]))
    }
}

final class ConflictStateQATests: XCTestCase {
    private func app(_ pid: Int32, _ bundleID: String?, _ name: String?) -> RunningAppInfo {
        RunningAppInfo(pid: pid, bundleID: bundleID, name: name)
    }

    func testReusedPIDByAnotherSwitcherSwapsTheName() {
        var s = ConflictState()
        s.apply(.launched(app(50, "com.talalfi.FlicKey", "FlicKey")))
        XCTAssertEqual(s.apply(.launched(app(50, nil, "Kawa")))?.runningSwitchers, ["Kawa"])
        XCTAssertEqual(s.apply(.terminated(pid: 50))?.runningSwitchers, [])
    }

    func testTerminateOfUnknownPIDKeepsOthers() {
        var s = ConflictState()
        s.apply(.launched(app(50, "com.talalfi.FlicKey", "FlicKey")))
        XCTAssertNil(s.apply(.terminated(pid: 999)))
        XCTAssertEqual(s.conflicts.runningSwitchers, ["FlicKey"])
    }

    func testOwnBundleIDWinsOverASwitcherName() {
        var s = ConflictState()
        XCTAssertNil(s.apply(.launched(app(7, "io.github.kytkin.Kytkin.dev", "FlicKey"))))
        XCTAssertNil(s.apply(.scan([app(8, "IO.GITHUB.KYTKIN.Kytkin", "Kawa")])))
        XCTAssertEqual(s.conflicts, .none)
    }

    func testScanReplacesEverythingButKeepsThePreference() {
        var s = ConflictState()
        s.apply(.perDocumentInput(true))
        s.apply(.launched(app(50, "com.talalfi.FlicKey", "FlicKey")))
        let out = s.apply(.scan([app(60, nil, "Punto Switcher")]))
        XCTAssertEqual(out, Conflicts(runningSwitchers: ["Punto Switcher"], perDocumentInputEnabled: true))
    }
}

final class FightCounterQATests: XCTestCase {
    private let ms: UInt64 = 1_000_000

    func testSameInstantCounts() {
        var f = FightCounter()
        f.ourSwitch(atNanos: 1_000 * ms)
        XCTAssertTrue(f.externalSwitch(atNanos: 1_000 * ms))
    }

    func testNewerOwnSwitchRestartsTheWindow() {
        var f = FightCounter()
        f.ourSwitch(atNanos: 1_000 * ms)
        f.ourSwitch(atNanos: 1_500 * ms)
        XCTAssertTrue(f.externalSwitch(atNanos: 1_700 * ms), "measured from the latest switch of ours")
        XCTAssertEqual(f.count, 1)
    }

    func testLateExternalLeavesNoFightButNextOwnSwitchStillCounts() {
        var f = FightCounter()
        f.ourSwitch(atNanos: 1_000 * ms)
        XCTAssertFalse(f.externalSwitch(atNanos: 2_000 * ms))
        f.ourSwitch(atNanos: 3_000 * ms)
        XCTAssertTrue(f.externalSwitch(atNanos: 3_100 * ms))
        XCTAssertEqual(f.count, 1)
    }

    func testCustomWindow() {
        var f = FightCounter(windowNanos: 50 * ms)
        f.ourSwitch(atNanos: 0)
        XCTAssertFalse(f.externalSwitch(atNanos: 60 * ms))
    }
}

@MainActor
final class ConflictDetectorQATests: XCTestCase {
    func testRefreshWithNoChangeDoesNotFireOnChange() {
        let flicKey = RunningAppInfo(pid: 50, bundleID: "com.talalfi.FlicKey", name: "FlicKey")
        let detector = ConflictDetector(workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                        runningApps: { [flicKey] }, readPerDocumentInput: { true },
                                        clock: FakeClock(nowNanos: 1), pollInterval: 0)
        detector.start()
        var changes = 0
        detector.onChange = { _ in changes += 1 }
        detector.refresh()
        detector.refresh()
        XCTAssertEqual(changes, 0)
        detector.stop()
    }

    func testStopKeepsLastStateAndRefreshStillWorks() {
        var on = true
        let detector = ConflictDetector(workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                        runningApps: { [] }, readPerDocumentInput: { on },
                                        clock: FakeClock(nowNanos: 1), pollInterval: 0)
        detector.start()
        detector.stop()
        XCTAssertTrue(detector.conflicts.pausesLearning, "stop() doesn't clear what was found")
        on = false
        detector.refresh()
        XCTAssertFalse(detector.conflicts.pausesLearning)
    }

    func testStopInvalidatesThePollTimer() {
        var reads = 0
        let detector = ConflictDetector(workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                        runningApps: { [] }, readPerDocumentInput: { reads += 1; return false },
                                        clock: FakeClock(), pollInterval: 0.05)
        detector.start()
        detector.stop()
        let after = reads
        let waited = expectation(description: "wait past several poll intervals")
        let t = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in waited.fulfill() }
        wait(for: [waited], timeout: 2)
        t.invalidate()
        XCTAssertEqual(reads, after)
    }
}
