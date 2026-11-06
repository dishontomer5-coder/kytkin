// P2-16: PermissionsManager plumbing with a fake probe, a recording fake requester and private notification
// centers (never the real workspace/app ones). SystemPermissionRequester isn't compiled into this target,
// so nothing here can show a permission prompt or open System Settings.

import AppKit
import XCTest

private final class FakeProbe: PermissionProbing, @unchecked Sendable { // @unchecked: main-thread tests only
    var reading = PermissionReading()
    private(set) var reads = 0
    func read() -> PermissionReading {
        reads += 1
        return reading
    }
}

@MainActor private final class RecordingRequester: PermissionRequesting {
    enum Call: Equatable { case accessibility, inputMonitoring, open(URL) }
    private(set) var calls: [Call] = []
    var onRequest: (() -> Void)?
    func requestAccessibility() { calls.append(.accessibility); onRequest?() }
    func requestInputMonitoring() { calls.append(.inputMonitoring); onRequest?() }
    func openSettings(_ url: URL) { calls.append(.open(url)) }
}

@MainActor
final class PermissionsManagerTests: XCTestCase {
    private let probe = FakeProbe()
    private let requester = RecordingRequester()
    private let clock = FakeClock(nowNanos: 1_000_000_000)
    private let workspace = NotificationCenter()
    private let app = NotificationCenter()
    private var manager: PermissionsManager!
    private var published: [PermissionStatus] = []

    override func setUp() async throws {
        manager = PermissionsManager(probe: probe, requester: requester, clock: clock,
                                     workspaceCenter: workspace, appCenter: app)
        manager.onChange = { [unowned self] in published.append($0) }
    }

    override func tearDown() async throws {
        manager.stop()
        manager = nil
    }

    private func activateSomeApp() {
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func testNothingIsReadBeforeStart() {
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(manager.accessibility, .unknown)
        XCTAssertNil(manager.scheduledPollNanos)
    }

    func testStartReadsOncePublishesAndSchedulesTheBackgroundPoll() {
        probe.reading = PermissionReading(accessibilityTrusted: true)
        manager.start()
        manager.start() // idempotent
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(manager.accessibility, .granted)
        XCTAssertEqual(manager.inputMonitoring, .notDetermined)
        XCTAssertEqual(manager.automation, [:]) // Phase 3
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.backgroundPollNanos)
    }

    func testTimerTickPublishesOnlyChanges() {
        manager.start()
        manager.pollTick()
        manager.pollTick()
        XCTAssertEqual(published.count, 1)
        probe.reading.secureInput = true
        manager.pollTick()
        XCTAssertEqual(published.count, 2)
        XCTAssertTrue(manager.secureInput)
        XCTAssertEqual(manager.status, published.last)
    }

    func testAppActivationReadsButBurstsAreCoalesced() {
        manager.start()
        clock.advance(bySeconds: 1)
        activateSomeApp()
        XCTAssertEqual(probe.reads, 2)
        clock.advance(byMilliseconds: 50)
        activateSomeApp()
        activateSomeApp()
        XCTAssertEqual(probe.reads, 2)
        clock.advance(byMilliseconds: 250)
        probe.reading.accessibilityTrusted = true // revoked/granted while running: noticed on the next app change
        activateSomeApp()
        XCTAssertEqual(probe.reads, 3)
        XCTAssertEqual(manager.accessibility, .granted)
    }

    func testKytkinBecomingActiveAlwaysReads() {
        manager.start()
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(probe.reads, 3)
    }

    func testStopRemovesObserversAndTheTimer() {
        manager.start()
        manager.stop()
        clock.advance(bySeconds: 1)
        activateSomeApp()
        app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(probe.reads, 1)
        XCTAssertNil(manager.scheduledPollNanos)
        manager.start() // restart re-reads and re-observes once
        clock.advance(bySeconds: 1)
        activateSomeApp()
        XCTAssertEqual(probe.reads, 3)
    }

    func testInteractiveScreenPollsEverySecondAndReadsAtOnce() {
        manager.start()
        manager.setInteractive(true)
        XCTAssertEqual(probe.reads, 2)
        XCTAssertEqual(manager.scheduledPollNanos, 1_000_000_000)
        manager.setInteractive(true) // no change, no extra read
        XCTAssertEqual(probe.reads, 2)
        manager.setInteractive(false)
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.backgroundPollNanos)
    }

    func testWatchingSecureInputPollsEverySecond() {
        manager.start()
        manager.setWatchesSecureInput(true)
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.secureInputPollNanos)
        manager.setWatchesSecureInput(false)
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.backgroundPollNanos)
    }

    func testIntervalChangesBeforeStartApplyOnStart() {
        manager.setInteractive(true)
        XCTAssertNil(manager.scheduledPollNanos)
        manager.start()
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.interactivePollNanos)
    }

    func testScreenAndSecureInputIntervalsCombine() {
        manager.start()
        manager.setWatchesSecureInput(true)
        manager.setInteractive(true)
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.interactivePollNanos)
        manager.setInteractive(false) // still watching Secure Input
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.secureInputPollNanos)
        manager.setWatchesSecureInput(false)
        XCTAssertEqual(manager.scheduledPollNanos, PermissionMonitor.backgroundPollNanos)
        manager.stop()
        XCTAssertNil(manager.scheduledPollNanos)
    }

    // P2-16 QA: the "fresh rows" read only happens while running; before start() / after stop() nothing is
    // read or published.
    func testScreenAndSecureInputTogglesDontReadWhileStopped() {
        manager.setInteractive(true)
        manager.setWatchesSecureInput(true)
        XCTAssertEqual(probe.reads, 0)
        XCTAssertEqual(published, [])
        manager.start()
        XCTAssertEqual(probe.reads, 1)
        manager.stop()
        manager.setInteractive(false)
        manager.setInteractive(true)
        XCTAssertEqual(probe.reads, 1)
    }

    func testRequestAccessibilityCallsTheRequesterThenReads() {
        manager.start()
        manager.requestAccessibility()
        XCTAssertEqual(requester.calls, [.accessibility])
        XCTAssertEqual(probe.reads, 2)
        XCTAssertEqual(manager.accessibility, .denied) // asked, not granted (yet)
        XCTAssertEqual(manager.inputMonitoring, .notDetermined)
        probe.reading.accessibilityTrusted = true // the user flips the switch; the 1 s poll sees it
        manager.pollTick()
        XCTAssertEqual(manager.accessibility, .granted)
    }

    func testRequestInputMonitoringThenGrantShowsTheRelaunchHint() {
        manager.start()
        requester.onRequest = { self.probe.reading.inputMonitoringGranted = true }
        manager.requestInputMonitoring()
        XCTAssertEqual(requester.calls, [.inputMonitoring])
        XCTAssertEqual(manager.inputMonitoring, .granted)
        XCTAssertTrue(manager.status.inputMonitoringNeedsRelaunch)
    }

    func testOpenSystemSettingsOpensTheDeepLinkOnly() {
        manager.openSystemSettings(.accessibility)
        manager.openSystemSettings(.inputMonitoring)
        XCTAssertEqual(requester.calls, [.open(PermissionPane.accessibility.settingsURL),
                                         .open(PermissionPane.inputMonitoring.settingsURL)])
        XCTAssertEqual(probe.reads, 0)
    }

    func testReadsNeverRequest() {
        manager.start()
        manager.refresh()
        manager.pollTick()
        activateSomeApp()
        manager.setInteractive(true)
        manager.setWatchesSecureInput(true)
        XCTAssertEqual(requester.calls, [])
    }
}
