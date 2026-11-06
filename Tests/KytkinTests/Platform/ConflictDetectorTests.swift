// P2-19: The thin ConflictDetector adapter, driven by fake notifications on PRIVATE notification centers
// (never the real workspace one), a fake running-apps list and a fake preference read. Nothing here
// launches, quits, activates or messages any app, and no preference is written.

import AppKit
import XCTest

@MainActor
final class ConflictDetectorTests: XCTestCase {
    private let me = NSRunningApplication.current
    private let flicKey = RunningAppInfo(pid: 50, bundleID: "com.talalfi.FlicKey", name: "FlicKey")

    /// Some other running app (Finder, Dock…: read-only lookup) that stands in for a switcher in
    /// launch/terminate notifications, via a test-only entry naming its bundle ID. The test process
    /// itself can't: its bundle ID may start with Kytkin's own prefix, which never matches.
    private func standIn() throws -> (app: NSRunningApplication, entries: [KnownSwitcher]) {
        let app = NSWorkspace.shared.runningApplications.first {
            guard let id = $0.bundleIdentifier else { return false }
            return !id.hasPrefix(KnownSwitchers.ownBundleIDPrefix)
        }
        guard let app, let id = app.bundleIdentifier else { throw XCTSkip("no running app to stand in") }
        return (app, [KnownSwitcher(name: "Stand-in", bundleIDs: [id], nameContains: "")])
    }

    /// What the fake closures return; a class so tests can change it after the closures captured it.
    private final class FakeSystem {
        var apps: [RunningAppInfo] = []
        var perDocumentOn = false
    }

    private func post(_ name: Notification.Name, on center: NotificationCenter, app: NSRunningApplication?) {
        let info: [AnyHashable: Any]? = app.map { [NSWorkspace.applicationUserInfoKey: $0] }
        center.post(name: name, object: nil, userInfo: info)
    }

    private func makeDetector(workspace: NotificationCenter = NotificationCenter(),
                              app: NotificationCenter = NotificationCenter(),
                              apps: @escaping @MainActor () -> [RunningAppInfo] = { [] },
                              perDocument: @escaping @MainActor () -> Bool = { false },
                              entries: [KnownSwitcher] = KnownSwitchers.entries,
                              clock: FakeClock = FakeClock(nowNanos: 1)) -> ConflictDetector {
        ConflictDetector(workspaceCenter: workspace, appCenter: app, runningApps: apps,
                         readPerDocumentInput: perDocument, entries: entries, clock: clock, pollInterval: 0)
    }

    func testStartScansAndReadsOnce() {
        var reads = 0
        let detector = makeDetector(apps: { [self.flicKey] }, perDocument: { reads += 1; return true })
        var changes: [Conflicts] = []
        detector.onChange = { changes.append($0) }
        detector.start()
        detector.start() // idempotent
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(detector.conflicts, Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: true))
        XCTAssertEqual(detector.runningSwitchers, ["FlicKey"])
        XCTAssertTrue(detector.perDocumentInputEnabled)
        XCTAssertTrue(detector.conflicts.pausesLearning)
        XCTAssertEqual(changes.count, 2, "one for the scan, one for the preference")
        detector.stop()
    }

    func testNothingRunningNothingReported() {
        let detector = makeDetector(apps: { [RunningAppInfo(pid: 1, bundleID: "com.apple.finder", name: "Finder")] })
        var changes = 0
        detector.onChange = { _ in changes += 1 }
        detector.start()
        XCTAssertEqual(detector.conflicts, .none)
        XCTAssertEqual(changes, 0)
        detector.stop()
    }

    func testLaunchAndTerminateNotifications() throws {
        let (other, entries) = try standIn()
        let workspace = NotificationCenter()
        let detector = makeDetector(workspace: workspace, entries: entries)
        var changes: [[String]] = []
        detector.onChange = { changes.append($0.runningSwitchers) }
        detector.start()

        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, app: other)
        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, app: other) // duplicate: no change
        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, app: nil)   // no app: ignored
        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, app: me)    // not a switcher
        post(NSWorkspace.didTerminateApplicationNotification, on: workspace, app: other)
        XCTAssertEqual(changes, [["Stand-in"], []])
        detector.stop()
    }

    func testPreferenceReReadOnAnyActivationAndOnOwnActivation() {
        let workspace = NotificationCenter()
        let appCenter = NotificationCenter()
        let fake = FakeSystem()
        var reads = 0
        let detector = makeDetector(workspace: workspace, app: appCenter,
                                    perDocument: { reads += 1; return fake.perDocumentOn })
        var changes: [Bool] = []
        detector.onChange = { changes.append($0.perDocumentInputEnabled) }
        detector.start()
        XCTAssertEqual(reads, 1)

        fake.perDocumentOn = true
        post(NSWorkspace.didActivateApplicationNotification, on: workspace, app: me)
        XCTAssertTrue(detector.perDocumentInputEnabled)
        post(NSWorkspace.didActivateApplicationNotification, on: workspace, app: me)  // same value: no change
        fake.perDocumentOn = false
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(detector.perDocumentInputEnabled)
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(changes, [true, false])
        detector.stop()
    }

    func testRefreshRescansAndReReads() {
        let fake = FakeSystem()
        let detector = makeDetector(apps: { fake.apps }, perDocument: { fake.perDocumentOn })
        detector.start()
        XCTAssertEqual(detector.conflicts, .none)
        fake.apps = [flicKey]
        fake.perDocumentOn = true
        detector.refresh()
        XCTAssertEqual(detector.conflicts, Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: true))
        fake.apps = []
        detector.refresh()
        XCTAssertEqual(detector.runningSwitchers, [])
        detector.stop()
    }

    func testStopRemovesObservers() throws {
        let (other, entries) = try standIn()
        let workspace = NotificationCenter()
        let appCenter = NotificationCenter()
        var reads = 0
        let detector = makeDetector(workspace: workspace, app: appCenter, perDocument: { reads += 1; return false },
                                    entries: entries)
        detector.start()
        detector.stop()
        post(NSWorkspace.didLaunchApplicationNotification, on: workspace, app: other)
        post(NSWorkspace.didActivateApplicationNotification, on: workspace, app: me)
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(detector.runningSwitchers, [])
    }

    func testRestartObservesOnce() {
        let workspace = NotificationCenter()
        var reads = 0
        let detector = makeDetector(workspace: workspace, perDocument: { reads += 1; return false })
        detector.start()
        detector.stop()
        detector.start()
        XCTAssertEqual(reads, 2)
        post(NSWorkspace.didActivateApplicationNotification, on: workspace, app: me)
        XCTAssertEqual(reads, 3, "one observer, not two")
        detector.stop()
    }

    func testFightCounter() {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        let detector = makeDetector(clock: clock)
        var changes = 0
        detector.onChange = { _ in changes += 1 }
        detector.noteOurSwitch()
        clock.advance(byMilliseconds: 100)
        detector.noteExternalSwitch()
        XCTAssertEqual(detector.repeatedFights, 1)
        clock.advance(byMilliseconds: 100)
        detector.noteExternalSwitch()                 // no new switch of ours
        detector.noteOurSwitch()
        clock.advance(byMilliseconds: 400)
        detector.noteExternalSwitch()                 // too late
        XCTAssertEqual(detector.repeatedFights, 1)
        XCTAssertEqual(changes, 0, "fights don't fire onChange")
    }

    func testPollTimerFires() {
        var reads = 0
        let detector = ConflictDetector(workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                        runningApps: { [] }, readPerDocumentInput: { reads += 1; return false },
                                        clock: FakeClock(), pollInterval: 0.05)
        detector.start()
        let polled = expectation(description: "poll")
        let check = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in polled.fulfill() }
        wait(for: [polled], timeout: 2)
        check.invalidate()
        XCTAssertGreaterThan(reads, 1)
        detector.stop()
    }

    /// The real read is read-only and never throws; its value depends on the Mac, so it isn't asserted.
    func testRealPreferenceReadIsHarmless() {
        _ = PerDocumentInputReader.isEnabled()
    }
}
