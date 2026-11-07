// P2-16: The pure permission logic: state mapping, change detection, coalescing and poll intervals.

import XCTest

final class PermissionMonitorTests: XCTestCase {
    private let clock = FakeClock(nowNanos: 1_000_000_000)

    private func reading(ax: Bool = false, im: Bool = false) -> PermissionReading {
        PermissionReading(accessibilityTrusted: ax, inputMonitoringGranted: im)
    }

    func testEverythingUnknownBeforeTheFirstRead() {
        let monitor = PermissionMonitor(clock: clock)
        XCTAssertFalse(monitor.hasRead)
        XCTAssertEqual(monitor.status.grants.accessibility, .unknown)
        XCTAssertEqual(monitor.status.grants.inputMonitoring, .unknown)
        XCTAssertEqual(monitor.status.grants.automation, [:])
        XCTAssertFalse(monitor.status.inputMonitoringNeedsRelaunch)
    }

    func testFirstReadAlwaysPublishes() {
        var monitor = PermissionMonitor(clock: clock)
        let status = monitor.ingest(reading())
        XCTAssertTrue(monitor.hasRead)
        XCTAssertEqual(status?.grants.accessibility, .notDetermined)
        XCTAssertEqual(status?.grants.inputMonitoring, .notDetermined)
    }

    func testGrantedMapsToGranted() {
        var monitor = PermissionMonitor(clock: clock)
        let status = monitor.ingest(reading(ax: true, im: true))
        XCTAssertEqual(status?.grants, PermissionGrants(accessibility: .granted, inputMonitoring: .granted))
    }

    func testSameReadingTwiceIsNoChange() {
        var monitor = PermissionMonitor(clock: clock)
        XCTAssertNotNil(monitor.ingest(reading(ax: true)))
        XCTAssertNil(monitor.ingest(reading(ax: true)))
        clock.advance(bySeconds: 10)
        XCTAssertNil(monitor.ingest(reading(ax: true)))
    }

    func testEachFieldChangeIsPublished() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        XCTAssertEqual(monitor.ingest(reading(ax: true))?.grants.accessibility, .granted)
        XCTAssertEqual(monitor.ingest(reading(ax: true, im: true))?.grants.inputMonitoring, .granted)
        // Revoke while running (001 §6.2).
        XCTAssertEqual(monitor.ingest(reading(ax: false, im: true))?.grants.accessibility, .notDetermined)
    }

    func testNotGrantedAfterARequestIsDenied() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        monitor.noteRequested(.accessibility)
        let status = monitor.ingest(reading())
        XCTAssertEqual(status?.grants.accessibility, .denied)
        XCTAssertEqual(status?.grants.inputMonitoring, .notDetermined) // only the asked one
        monitor.noteRequested(.inputMonitoring)
        XCTAssertEqual(monitor.ingest(reading())?.grants.inputMonitoring, .denied)
    }

    func testGrantAfterARequestIsGrantedAndARevokeIsDenied() {
        var monitor = PermissionMonitor(clock: clock)
        monitor.noteRequested(.accessibility)
        XCTAssertEqual(monitor.ingest(reading(ax: false))?.grants.accessibility, .denied)
        XCTAssertEqual(monitor.ingest(reading(ax: true))?.grants.accessibility, .granted)
        XCTAssertEqual(monitor.ingest(reading(ax: false))?.grants.accessibility, .denied)
    }

    func testStatusFeedsFeatureAvailability() throws {
        var monitor = PermissionMonitor(clock: clock)
        let status = try XCTUnwrap(monitor.ingest(reading(ax: true, im: false)))
        // P2-45: Secure Input comes from KeyWatcherStatus.secureInputOn (P2-20), not from PermissionStatus.
        let availability = FeatureAvailability.compute(grants: status.grants, tapMode: .active,
                                                       secureInput: true, settings: FeatureSettings())
        XCTAssertTrue(availability.appSwitching)
        XCTAssertFalse(availability.doubleShiftConvert) // Secure Input
        XCTAssertTrue(availability.doubleShiftToggleOnly)
        XCTAssertTrue(availability.siteRules)
    }

    // MARK: - Input Monitoring "Quit & Reopen"

    func testInputMonitoringGrantedMidRunNeedsRelaunch() {
        var monitor = PermissionMonitor(clock: clock)
        XCTAssertEqual(monitor.ingest(reading(im: false))?.inputMonitoringNeedsRelaunch, false)
        XCTAssertEqual(monitor.ingest(reading(im: true))?.inputMonitoringNeedsRelaunch, true)
        // A revoke clears it; a re-grant in the same run needs the relaunch again.
        XCTAssertEqual(monitor.ingest(reading(im: false))?.inputMonitoringNeedsRelaunch, false)
        XCTAssertEqual(monitor.ingest(reading(im: true))?.inputMonitoringNeedsRelaunch, true)
    }

    func testInputMonitoringGrantedAtLaunchNeedsNoRelaunch() {
        var monitor = PermissionMonitor(clock: clock)
        XCTAssertEqual(monitor.ingest(reading(im: true))?.inputMonitoringNeedsRelaunch, false)
        _ = monitor.ingest(reading(im: false))
        // P2-16 QA: granted at launch, revoked, granted again: KeyWatcher dropped the tap on the revoke and has
        // to create a new one, the same situation as a first grant mid-run, so the hint shows.
        XCTAssertEqual(monitor.ingest(reading(im: true))?.inputMonitoringNeedsRelaunch, true)
    }

    func testAccessibilityChangesNeverSetTheRelaunchHint() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading(ax: false, im: true))
        XCTAssertEqual(monitor.ingest(reading(ax: true, im: true))?.inputMonitoringNeedsRelaunch, false)
    }

    /// P2-64: on macOS 26 granting Accessibility makes the Input Monitoring preflight read true (the app is not in
    /// the Input Monitoring list). That must not look like a fresh Input Monitoring grant needing a relaunch.
    func testAccessibilityAloneMakingThePreflightTrueNeverNeedsARelaunch() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading(ax: false, im: false))
        let status = monitor.ingest(reading(ax: true, im: true))
        XCTAssertEqual(status?.grants.inputMonitoring, .granted)
        XCTAssertEqual(status?.inputMonitoringNeedsRelaunch, false)
        // Accessibility revoked again: the preflight follows it back to false; nothing to reopen for.
        XCTAssertEqual(monitor.ingest(reading(ax: false, im: false))?.inputMonitoringNeedsRelaunch, false)
        // A real Input Monitoring grant while Accessibility is off still needs the relaunch.
        XCTAssertEqual(monitor.ingest(reading(ax: false, im: true))?.inputMonitoringNeedsRelaunch, true)
        // ...until Accessibility is allowed: the active tap covers it.
        XCTAssertEqual(monitor.ingest(reading(ax: true, im: true))?.inputMonitoringNeedsRelaunch, false)
    }

    // MARK: - When to read

    func testEveryReasonReadsBeforeTheFirstRead() {
        let monitor = PermissionMonitor(clock: clock)
        for reason in [PermissionRefreshReason.launch, .appActivated, .kytkinActivated, .timer, .afterRequest, .manual] {
            XCTAssertTrue(monitor.shouldRead(reason), "\(reason)")
        }
    }

    func testAppActivationBurstsAreCoalesced() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        clock.advance(byMilliseconds: 100)
        XCTAssertFalse(monitor.shouldRead(.appActivated))
        clock.advance(byMilliseconds: 149)
        XCTAssertFalse(monitor.shouldRead(.appActivated))
        clock.advance(byMilliseconds: 1)
        XCTAssertTrue(monitor.shouldRead(.appActivated)) // exactly 250 ms after the last read
    }

    func testCoalescingCountsFromTheLastReadOfAnyKind() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        clock.advance(byMilliseconds: 300)
        XCTAssertTrue(monitor.shouldRead(.appActivated))
        _ = monitor.ingest(reading()) // e.g. a timer read, no change
        clock.advance(byMilliseconds: 10)
        XCTAssertFalse(monitor.shouldRead(.appActivated))
    }

    func testAnActivationRightAfterAnUncoalescedReadIsSkipped() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        clock.advance(bySeconds: 10)
        XCTAssertTrue(monitor.shouldRead(.kytkinActivated)) // Kytkin's own activation reads...
        _ = monitor.ingest(reading())
        XCTAssertFalse(monitor.shouldRead(.appActivated)) // ...so the paired app-activation is coalesced
    }

    func testOnlyAppActivationIsCoalesced() {
        var monitor = PermissionMonitor(clock: clock)
        _ = monitor.ingest(reading())
        for reason in [PermissionRefreshReason.launch, .kytkinActivated, .timer, .afterRequest, .manual] {
            XCTAssertTrue(monitor.shouldRead(reason), "\(reason)")
        }
    }

    func testPollIntervals() {
        var monitor = PermissionMonitor(clock: clock)
        XCTAssertEqual(monitor.pollIntervalNanos, PermissionMonitor.backgroundPollNanos)
        XCTAssertEqual(PermissionMonitor.backgroundPollNanos, 5_000_000_000)
        monitor.interactive = true
        XCTAssertEqual(monitor.pollIntervalNanos, 1_000_000_000)
        XCTAssertEqual(PermissionMonitor.interactivePollNanos, 1_000_000_000)
        monitor.interactive = false
        XCTAssertEqual(monitor.pollIntervalNanos, PermissionMonitor.backgroundPollNanos)
    }

    // MARK: - Panes

    func testSettingsDeepLinks() {
        XCTAssertEqual(PermissionPane.accessibility.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionPane.inputMonitoring.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(PermissionPane.allCases.count, 2)
    }
}
