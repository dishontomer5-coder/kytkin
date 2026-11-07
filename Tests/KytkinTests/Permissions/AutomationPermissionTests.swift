// P3-7: Automation permission per browser (001 §14.7): the OSStatus mapping, the tracker's throttle, PermissionsManager
// with fake seams (checks off main, results on main, the request only from the click path), the Settings seam for
// P3-15 (`BrowserAutomationController`, the row state and its plain-English strings), and AppController's silent
// checks at launch and on activation of an opted-in browser. No fake here talks to TCC or any app.

import AppKit
import XCTest

private final class FakeAutomationProbe: AutomationPermissionChecking, @unchecked Sendable { // test thread only
    var answers: [String: AutomationCheckResult] = [:]
    private(set) var checks: [String] = []
    func check(bundleID: String) -> AutomationCheckResult {
        checks.append(bundleID)
        return answers[bundleID] ?? .notAsked
    }
}

private final class FakeAutomationRequester: AutomationPermissionRequesting, @unchecked Sendable { // test thread only
    var answer: AutomationCheckResult = .granted
    private(set) var asks: [String] = []
    func ask(bundleID: String) -> AutomationCheckResult {
        asks.append(bundleID)
        return answer
    }
}

private final class NoProbe: PermissionProbing {
    func read() -> PermissionReading { PermissionReading() }
}

@MainActor private final class NoRequester: PermissionRequesting {
    private(set) var opened: [URL] = []
    func requestAccessibility() {}
    func requestInputMonitoring() {}
    func openSettings(_ url: URL) { opened.append(url) }
}

final class AutomationPermissionTrackerTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000

    func testStatusMapping() {
        XCTAssertEqual(AutomationCheckResult(status: 0), .granted)
        XCTAssertEqual(AutomationCheckResult(status: -1743), .denied)
        XCTAssertEqual(AutomationCheckResult(status: -1744), .notAsked)
        XCTAssertEqual(AutomationCheckResult(status: -600), .notRunning)
        XCTAssertEqual(AutomationCheckResult(status: -50), .failed)
    }

    func testSilentChecksAreThrottledPerBrowserAndNeverDoubled() {
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.beginSilentCheck("chrome", now: t0))
        XCTAssertFalse(t.beginSilentCheck("chrome", now: t0 + 6_000_000_000), "still in flight")
        XCTAssertTrue(t.beginSilentCheck("arc", now: t0), "per browser")
        _ = t.ingest("chrome", .granted)
        XCTAssertFalse(t.beginSilentCheck("chrome", now: t0 + 4_999_999_999))
        XCTAssertTrue(t.beginSilentCheck("chrome", now: t0 + 5_000_000_000))
    }

    func testNotRunningAndFailuresKeepTheLastState() {
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.ingest("chrome", .granted))
        XCTAssertFalse(t.ingest("chrome", .notRunning))
        XCTAssertFalse(t.ingest("chrome", .failed))
        XCTAssertEqual(t.states["chrome"], .granted)
        XCTAssertTrue(t.ingest("chrome", .denied))
        XCTAssertTrue(t.ingest("chrome", .notAsked))
        XCTAssertEqual(t.states["chrome"], .notDetermined)
        XCTAssertFalse(t.ingest("safari", .notRunning))
        XCTAssertNil(t.states["safari"], "never answered: unknown")
    }

    func testAutomationSettingsURL() {
        XCTAssertEqual(PermissionPane.automationSettingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }
}

@MainActor
final class PermissionsManagerAutomationTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private var probe: FakeAutomationProbe!
    private var requester: FakeAutomationRequester!
    private var plain: NoRequester!
    private var clock: FakeClock!
    private var manager: PermissionsManager!
    private var published: [PermissionStatus] = []
    private var offMainRuns = 0

    override func setUp() async throws {
        probe = FakeAutomationProbe()
        requester = FakeAutomationRequester()
        plain = NoRequester()
        clock = FakeClock(nowNanos: 1_000_000_000)
        published = []
        offMainRuns = 0
        manager = PermissionsManager(probe: NoProbe(), requester: plain, clock: clock,
                                     workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                     automationProbe: probe, automationRequester: requester,
                                     background: { [unowned self] work, done in
                                         offMainRuns += 1
                                         done(work())
                                     })
        manager.onChange = { [unowned self] in published.append($0) }
    }

    func testSilentCheckPublishesTheState() {
        probe.answers[chrome] = .granted
        manager.refreshAutomation(for: [chrome])
        XCTAssertEqual(probe.checks, [chrome])
        XCTAssertEqual(offMainRuns, 1, "the check runs off main")
        XCTAssertEqual(manager.automation[chrome], .granted)
        XCTAssertEqual(published.last?.grants.automation, [chrome: .granted])
        XCTAssertTrue(requester.asks.isEmpty, "a refresh never asks")
    }

    func testRefreshIsThrottledAndUnchangedStatesDontPublish() {
        manager.refreshAutomation(for: [chrome])
        manager.refreshAutomation(for: [chrome])
        XCTAssertEqual(probe.checks.count, 1)
        clock.advance(bySeconds: 5)
        manager.refreshAutomation(for: [chrome])
        XCTAssertEqual(probe.checks.count, 2)
        XCTAssertEqual(published.count, 1, "same answer: no second onChange")
    }

    func testRequestAsksAndPublishes() {
        requester.answer = .denied
        manager.requestAutomation(for: chrome)
        XCTAssertEqual(requester.asks, [chrome])
        XCTAssertEqual(manager.automation[chrome], .denied)
    }

    func testAutomationSurvivesTheNextAccessibilityRead() {
        probe.answers[chrome] = .granted
        manager.refreshAutomation(for: [chrome])
        manager.start()   // the regular read must carry the automation states on
        XCTAssertEqual(manager.status.grants.automation, [chrome: .granted])
        manager.stop()
    }

    func testOpenAutomationSettings() {
        manager.openAutomationSettings()
        XCTAssertEqual(plain.opened, [PermissionPane.automationSettingsURL])
    }

    func testWithoutSeamsNothingHappens() {
        let m = PermissionsManager(probe: NoProbe(), requester: plain, clock: clock,
                                   workspaceCenter: NotificationCenter(), appCenter: NotificationCenter())
        m.refreshAutomation(for: [chrome])
        m.requestAutomation(for: chrome)
        XCTAssertEqual(m.automation, [:])
    }
}

@MainActor
final class BrowserAutomationControllerTests: XCTestCase {
    private let chrome = "com.google.Chrome"
    private let arc = "company.thebrowser.Browser"
    private let safari = "com.apple.Safari"
    private let zen = "app.zen-browser.zen"
    private let orion = "com.kagi.kagimacOS"
    private var permissions: RecordingPermissions!
    private var store: PreferencesStore!
    private var running: Set<String> = []
    private var sut: BrowserAutomationController!

    override func setUp() async throws {
        permissions = RecordingPermissions()
        store = makeStore(clock: FakeClock())
        running = [chrome, arc, zen]
        sut = BrowserAutomationController(store: store, permissions: permissions,
                                          isRunning: { [unowned self] in running.contains($0) })
    }

    func testGeckoAndUnknownBrowsersAreNotAvailable() {
        XCTAssertEqual(sut.automationState(for: zen).status, .notAvailableGecko)
        XCTAssertEqual(sut.automationState(for: zen).statusText(browserName: "Zen"),
                       "Automation isn't available for Firefox-based browsers.")
        XCTAssertEqual(sut.automationState(for: "org.mozilla.firefox").status, .notAvailableGecko)
        XCTAssertEqual(sut.automationState(for: orion).status, .notAvailable)
        XCTAssertEqual(sut.automationState(for: "com.example.Other").status, .notAvailable)
        XCTAssertFalse(sut.automationState(for: zen).isAvailable)
        sut.setAutomationEnabled(true, for: zen)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [:], "no toggle for Zen")
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    func testOffByDefault() {
        let s = sut.automationState(for: chrome)
        XCTAssertEqual(s.status, .off)
        XCTAssertTrue(s.isAvailable)
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.statusText(browserName: "Chrome"), "Off")
        XCTAssertNil(s.action)
    }

    func testTurningOnARunningBrowserAsksOnThatClick() {
        sut.setAutomationEnabled(true, for: chrome)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [chrome: true])
        XCTAssertEqual(permissions.calls, [.requestAutomation(chrome)])
        XCTAssertEqual(sut.automationState(for: chrome).status, .checking)
        permissions.set(automation: chrome, .granted)
        XCTAssertEqual(sut.automationState(for: chrome).status, .allowed)
        XCTAssertEqual(sut.automationState(for: chrome).statusText(browserName: "Chrome"), "Allowed")
    }

    func testTurningOnABrowserThatIsntRunningOnlyStoresTheChoice() {
        running = []
        sut.setAutomationEnabled(true, for: safari)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [safari: true])
        XCTAssertTrue(permissions.calls.isEmpty, "never asks later on its own")
        let s = sut.automationState(for: safari)
        XCTAssertEqual(s.status, .notAsked)
        XCTAssertEqual(s.statusText(browserName: "Safari"), "Not asked yet. Open Safari, then click Ask.")
        XCTAssertEqual(s.action, .ask)
        XCTAssertFalse(s.actionEnabled, "Ask needs the browser running")
        sut.askAutomation(for: safari)
        XCTAssertTrue(permissions.calls.isEmpty)
        running = [safari]
        sut.askAutomation(for: safari)
        XCTAssertEqual(permissions.calls, [.requestAutomation(safari)])
    }

    func testAlreadyAllowedIsNotAskedAgain() {
        permissions.set(automation: chrome, .granted)
        sut.setAutomationEnabled(true, for: chrome)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    func testDeniedShowsTheSystemSettingsLink() {
        sut.setAutomationEnabled(true, for: arc)
        permissions.set(automation: arc, .denied)
        let s = sut.automationState(for: arc)
        XCTAssertEqual(s.status, .denied)
        XCTAssertEqual(s.action, .openSystemSettings)
        XCTAssertEqual(s.actionTitle(), "Open System Settings")
        XCTAssertTrue(s.actionEnabled)
        XCTAssertTrue(s.statusText(browserName: "Arc").hasPrefix("Denied."))
        sut.openAutomationSettings()
        XCTAssertEqual(permissions.calls.last, .openAutomationSettings)
    }

    func testNotAskedWhileRunningOffersAsk() {
        sut.setAutomationEnabled(true, for: chrome)
        permissions.set(automation: chrome, .notDetermined)
        let s = sut.automationState(for: chrome)
        XCTAssertEqual(s.status, .notAsked)
        XCTAssertEqual(s.actionTitle(), "Ask")
        XCTAssertTrue(s.actionEnabled)
    }

    func testTurningOffOnlyStoresTheChoice() {
        sut.setAutomationEnabled(true, for: chrome)
        sut.setAutomationEnabled(false, for: chrome)
        XCTAssertEqual(store.prefs.browsers.appleEventsOptIn, [:])
        XCTAssertEqual(permissions.calls, [.requestAutomation(chrome)], "turning off asks nothing")
        XCTAssertEqual(sut.automationState(for: chrome).status, .off)
    }

    func testAskWhenNotOptedInDoesNothing() {
        sut.askAutomation(for: chrome)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    func testRefreshIsSilentAndSkipsBrowsersWithoutADictionary() {
        sut.refreshAutomation(for: [chrome, zen, orion, safari])
        XCTAssertEqual(permissions.calls, [.refreshAutomation([chrome, safari])])
        XCTAssertTrue(permissions.promptingCalls.isEmpty)
    }
}

@MainActor
final class AutomationWiringTests: XCTestCase {
    private let chrome = "com.google.Chrome"

    private func make(optIn: [String: Bool]) -> (AppController, FakePermissions, FakeContextMonitor) {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        var prefs = Preferences()
        prefs.browsers.appleEventsOptIn = optIn
        let monitor = FakeContextMonitor()
        let permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .granted))
        let sut = AppController(switcher: FakeSwitcher(current: IDs.abc), context: monitor,
                                store: makeStore(prefs, clock: clock), permissions: permissions,
                                conflicts: FakeConflicts(), keyWatcher: FakeKeyWatcher(), ticker: FakeTicker(),
                                clock: clock, suffixListLoaded: true, webLinkHandlers: { [] })
        monitor.onChange = { sut.contextDidChange($0) }
        permissions.onChange = { sut.permissionsDidChange($0) }
        sut.start()
        return (sut, permissions, monitor)
    }

    func testLaunchChecksTheOptedInBrowsersSilently() {
        let (_, permissions, _) = make(optIn: [chrome: true, "com.apple.Safari": false])
        XCTAssertEqual(permissions.automationRefreshes.first, [chrome])
    }

    func testAnOptedInBrowserInFrontIsCheckedSilently() {
        let (_, permissions, monitor) = make(optIn: [chrome: true])
        monitor.activate("com.apple.Notes", pid: 3)
        let before = permissions.automationRefreshes.count
        monitor.activate(chrome, pid: 9)
        XCTAssertEqual(permissions.automationRefreshes.count, before + 1)
        XCTAssertEqual(permissions.automationRefreshes.last, [chrome])
    }

    func testAGrantPutsTheDialectIntoTheWatchRequest() {
        let (_, permissions, monitor) = make(optIn: [chrome: true])
        XCTAssertNil(monitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, "not granted yet")
        permissions.status.grants.automation = [chrome: .granted]
        permissions.onChange?(permissions.status)
        XCTAssertEqual(monitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, .chromium)
    }
}
