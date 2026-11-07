// P3-7: Automation permission per browser (001 §14.7): the OSStatus mapping, the tracker's throttle, PermissionsManager
// with fake seams (checks off main, results on main, the request only from the click path), the Settings seam for
// P3-15 (`BrowserAutomationController`, the row state and its plain-English strings), and AppController's silent
// checks at launch and on activation of an opted-in browser. No fake here talks to TCC or any app.
// P3-26: one global switch (`browsers.useAutomation`); click requests are queued so macOS never shows two questions
// at once; a browser coming to the front is only ever checked silently (FakePermissions fails on any prompt).

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

    func testClickRequestsRunOneAtATime() {
        // P3-26: the global switch may ask for several running browsers; macOS must never show two questions at once.
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.beginRequest("chrome", now: t0), "nothing on screen: ask now")
        XCTAssertFalse(t.beginRequest("arc", now: t0), "queued")
        XCTAssertFalse(t.beginRequest("safari", now: t0), "queued")
        XCTAssertFalse(t.beginRequest("arc", now: t0), "already waiting: not twice")
        XCTAssertFalse(t.beginRequest("chrome", now: t0), "already on screen: not twice")
        XCTAssertEqual(t.requestInFlight, "chrome")
        XCTAssertEqual(t.requestQueue, ["arc", "safari"])
        XCTAssertNil(t.finishRequest("arc", token: t.requestToken, now: t0), "only the one on screen finishes")
        XCTAssertEqual(t.finishRequest("chrome", token: t.requestToken, now: t0), "arc")
        XCTAssertEqual(t.finishRequest("arc", token: t.requestToken, now: t0), "safari")
        XCTAssertNil(t.finishRequest("safari", token: t.requestToken, now: t0))
        XCTAssertNil(t.requestInFlight)
        XCTAssertTrue(t.beginRequest("chrome", now: t0), "free again")
    }

    func testAnUnansweredRequestDoesNotBlockLaterClicksForever() {
        // P3-26 QA: a question left open (or a call stuck on a hung browser) must not dead-end every later Ask.
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.beginRequest("chrome", now: t0))
        let stuck = t.requestToken
        let wait = AutomationPermissionTracker.maxRequestWaitNanos
        XCTAssertFalse(t.beginRequest("arc", now: t0 + wait - 1), "still waiting: queued")
        XCTAssertTrue(t.beginRequest("safari", now: t0 + wait), "the stuck one is abandoned: this click asks now")
        XCTAssertEqual(t.requestInFlight, "safari")
        XCTAssertEqual(t.requestQueue, ["arc"], "the queue goes on behind it")
        XCTAssertNil(t.finishRequest("chrome", token: stuck, now: t0 + wait), "a late answer moves nothing on")
        XCTAssertEqual(t.requestInFlight, "safari")
        XCTAssertEqual(t.finishRequest("safari", token: t.requestToken, now: t0 + wait), "arc")
    }

    func testCancelDropsOnlyTheWaitingRequests() {
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.beginRequest("chrome", now: t0))
        XCTAssertFalse(t.beginRequest("arc", now: t0))
        t.cancelQueuedRequests()
        XCTAssertEqual(t.requestQueue, [])
        XCTAssertEqual(t.requestInFlight, "chrome", "the one on screen stays")
        XCTAssertNil(t.finishRequest("chrome", token: t.requestToken, now: t0), "nothing next")
    }

    func testALateAnswerForTheSameBrowserDoesNotFinishTheNewQuestion() {
        // P3-26 QA: Chrome stuck, then Ask on Chrome again after the wait: the old answer has a stale token.
        var t = AutomationPermissionTracker()
        XCTAssertTrue(t.beginRequest("chrome", now: t0))
        let stuck = t.requestToken
        let later = t0 + AutomationPermissionTracker.maxRequestWaitNanos
        XCTAssertTrue(t.beginRequest("chrome", now: later))
        XCTAssertFalse(t.beginRequest("arc", now: later), "queued behind the new question")
        XCTAssertNil(t.finishRequest("chrome", token: stuck, now: later))
        XCTAssertEqual(t.requestInFlight, "chrome", "the new question is still on screen")
        XCTAssertEqual(t.finishRequest("chrome", token: t.requestToken, now: later), "arc")
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

    func testRequestsWaitForTheQuestionOnScreen() {
        // P3-26: hold each answer, as macOS does while its question is on screen.
        var pending: [(@Sendable () -> AutomationCheckResult, @MainActor @Sendable (AutomationCheckResult) -> Void)] = []
        let m = PermissionsManager(probe: NoProbe(), requester: plain, clock: clock,
                                   workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                   automationProbe: probe, automationRequester: requester,
                                   background: { work, done in pending.append((work, done)) })
        let arc = "company.thebrowser.Browser"
        m.requestAutomation(for: chrome)
        m.requestAutomation(for: arc)
        XCTAssertEqual(pending.count, 1, "the second question waits")
        var rounds = 0
        while !pending.isEmpty && rounds < 5 {   // bounded
            rounds += 1
            let (work, done) = pending.removeFirst()
            done(work())
            XCTAssertLessThanOrEqual(pending.count, 1, "never two at once")
        }
        XCTAssertEqual(requester.asks, [chrome, arc], "then the next, in order")
        XCTAssertEqual(m.automation[arc], .granted)
    }

    func testANeverAnsweredQuestionDoesNotBlockAskForever() {
        // P3-26 QA: the first answer doesn't come back in time; after the wait a new click still asks, and the stuck
        // answer arriving late records its state but starts nothing.
        var pending: [(@Sendable () -> AutomationCheckResult, @MainActor @Sendable (AutomationCheckResult) -> Void)] = []
        let m = PermissionsManager(probe: NoProbe(), requester: plain, clock: clock,
                                   workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                   automationProbe: probe, automationRequester: requester,
                                   background: { work, done in pending.append((work, done)) })
        let arc = "company.thebrowser.Browser"
        let safari = "com.apple.Safari"
        m.requestAutomation(for: chrome)
        m.requestAutomation(for: arc)
        XCTAssertEqual(pending.count, 1)
        clock.advance(byNanos: AutomationPermissionTracker.maxRequestWaitNanos)
        m.requestAutomation(for: safari)
        XCTAssertEqual(pending.count, 2, "the new click asks")
        let (stuckWork, stuckDone) = pending.removeFirst()
        requester.answer = .denied
        stuckDone(stuckWork())   // Chrome's late answer
        XCTAssertEqual(m.automation[chrome], .denied, "its state is still taken")
        XCTAssertEqual(pending.count, 1, "but it starts nothing: Safari's question is on screen")
        requester.answer = .granted
        var rounds = 0
        while !pending.isEmpty && rounds < 5 {   // bounded
            rounds += 1
            let (work, done) = pending.removeFirst()
            done(work())
            XCTAssertLessThanOrEqual(pending.count, 1, "never two at once")
        }
        XCTAssertEqual(requester.asks, [chrome, safari, arc])
    }

    func testTurningTheSwitchOffDropsTheQuestionsStillWaiting() {
        // P3-26 QA: on (Chrome's question on screen, Arc waiting), then off: Arc must never be asked.
        var pending: [(@Sendable () -> AutomationCheckResult, @MainActor @Sendable (AutomationCheckResult) -> Void)] = []
        let m = PermissionsManager(probe: NoProbe(), requester: plain, clock: clock,
                                   workspaceCenter: NotificationCenter(), appCenter: NotificationCenter(),
                                   automationProbe: probe, automationRequester: requester,
                                   background: { work, done in pending.append((work, done)) })
        m.requestAutomation(for: chrome)
        m.requestAutomation(for: "company.thebrowser.Browser")
        m.cancelQueuedAutomationRequests()
        XCTAssertEqual(pending.count, 1)
        let (work, done) = pending.removeFirst()
        done(work())
        XCTAssertTrue(pending.isEmpty, "nothing more is asked")
        XCTAssertEqual(requester.asks, [chrome])
        XCTAssertEqual(m.automation[chrome], .granted, "the answer on screen still counts")
        m.requestAutomation(for: "company.thebrowser.Browser")
        XCTAssertEqual(pending.count, 1, "a later click asks normally")
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
        sut.setUseAutomation(true)
        XCTAssertEqual(sut.automationState(for: zen).status, .notAvailableGecko, "P3-26: the switch is ignored for Zen")
        XCTAssertFalse(permissions.calls.contains(.requestAutomation(zen)), "running, but never asked")
        sut.askAutomation(for: zen)
        XCTAssertFalse(permissions.calls.contains(.requestAutomation(zen)))
    }

    func testOffByDefault() {
        let s = sut.automationState(for: chrome)
        XCTAssertEqual(s.status, .off)
        XCTAssertTrue(s.isAvailable)
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.statusText(browserName: "Chrome"), "Off (\"Use Automation\" is off above)")
        XCTAssertNil(s.action)
    }

    func testTurningOnAsksTheRunningBrowsersOnThatClick() {
        sut.setUseAutomation(true)
        XCTAssertTrue(store.prefs.browsers.useAutomation)
        XCTAssertEqual(permissions.calls, [.requestAutomation(chrome), .requestAutomation(arc)],
                       "Chrome and Arc run and support it; Zen runs but has no Automation; Safari isn't running")
        XCTAssertEqual(sut.automationState(for: chrome).status, .checking)
        permissions.set(automation: chrome, .granted)
        XCTAssertEqual(sut.automationState(for: chrome).status, .allowed)
        XCTAssertEqual(sut.automationState(for: chrome).statusText(browserName: "Chrome"), "Allowed")
    }

    func testTurningOnWithNoBrowserRunningOnlyStoresTheChoice() {
        running = []
        sut.setUseAutomation(true)
        XCTAssertTrue(store.prefs.browsers.useAutomation)
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
        permissions.set(automation: arc, .granted)
        sut.setUseAutomation(true)
        XCTAssertTrue(permissions.calls.isEmpty)
    }

    func testDeniedShowsTheSystemSettingsLink() {
        sut.setUseAutomation(true)
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
        sut.setUseAutomation(true)
        permissions.set(automation: chrome, .notDetermined)
        let s = sut.automationState(for: chrome)
        XCTAssertEqual(s.status, .notAsked)
        XCTAssertEqual(s.actionTitle(), "Ask")
        XCTAssertTrue(s.actionEnabled)
    }

    func testTurningOffOnlyStoresTheChoice() {
        running = [chrome]
        sut.setUseAutomation(true)
        sut.setUseAutomation(false)
        XCTAssertFalse(store.prefs.browsers.useAutomation)
        XCTAssertEqual(permissions.calls, [.requestAutomation(chrome), .cancelQueuedAutomationRequests],
                       "turning off asks nothing; it drops questions still waiting (P3-26 QA)")
        XCTAssertEqual(sut.automationState(for: chrome).status, .off)
        sut.setUseAutomation(false)
        XCTAssertEqual(permissions.calls.count, 2, "a repeated set does nothing")
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

    private func make(useAutomation: Bool) -> (AppController, FakePermissions, FakeContextMonitor) {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        var prefs = Preferences()
        prefs.browsers.useAutomation = useAutomation
        let monitor = FakeContextMonitor()
        let permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .granted))
        let sut = AppController(switcher: FakeSwitcher(current: IDs.abc), context: monitor,
                                store: makeStore(prefs, clock: clock), permissions: permissions,
                                conflicts: FakeConflicts(), keyWatcher: FakeKeyWatcher(), ticker: FakeTicker(),
                                clock: clock, suffixListLoaded: true,
                                webLinkHandlers: { ["com.google.Chrome", "com.apple.Safari", "app.zen-browser.zen"] })
        monitor.onChange = { sut.contextDidChange($0) }
        permissions.onChange = { sut.permissionsDidChange($0) }
        sut.start()
        return (sut, permissions, monitor)
    }

    func testLaunchChecksTheInstalledBrowsersThatSupportItSilently() {
        let (_, permissions, _) = make(useAutomation: true)
        XCTAssertEqual(permissions.automationRefreshes.first, [chrome, "com.apple.Safari"], "not Zen; never a prompt")
    }

    func testSwitchOffChecksNothing() {
        let (_, permissions, monitor) = make(useAutomation: false)
        monitor.activate(chrome, pid: 9)
        XCTAssertTrue(permissions.automationRefreshes.allSatisfy(\.isEmpty))
    }

    func testABrowserInFrontIsCheckedSilentlyNeverAsked() {
        let (_, permissions, monitor) = make(useAutomation: true)
        monitor.activate("com.apple.Notes", pid: 3)
        let before = permissions.automationRefreshes.count
        monitor.activate(chrome, pid: 9)
        XCTAssertEqual(permissions.automationRefreshes.count, before + 1)
        XCTAssertEqual(permissions.automationRefreshes.last, [chrome], "silent; a prompt would fail the test")
        let count = permissions.automationRefreshes.count
        monitor.activate("app.zen-browser.zen", pid: 10)
        XCTAssertEqual(permissions.automationRefreshes.count, count, "Zen: no Automation, no check")
    }

    func testAGrantPutsTheDialectIntoTheWatchRequest() {
        let (_, permissions, monitor) = make(useAutomation: true)
        XCTAssertNil(monitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, "not granted yet")
        permissions.status.grants.automation = [chrome: .granted]
        permissions.onChange?(permissions.status)
        XCTAssertEqual(monitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, .chromium)
    }

    func testTheGlobalSwitchGatesTheDialect() {
        // P3-26: global switch × browser supports it × macOS allowed it.
        let (_, permissions, monitor) = make(useAutomation: false)
        permissions.status.grants.automation = [chrome: .granted, "app.zen-browser.zen": .granted]
        permissions.onChange?(permissions.status)
        XCTAssertNil(monitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, "switch off")
        let (_, onPermissions, onMonitor) = make(useAutomation: true)
        onPermissions.status.grants.automation = [chrome: .granted, "app.zen-browser.zen": .granted]
        onPermissions.onChange?(onPermissions.status)
        XCTAssertEqual(onMonitor.sitePolicyCalls.last?.request(for: chrome)?.appleScript, .chromium)
        XCTAssertNil(onMonitor.sitePolicyCalls.last?.request(for: "app.zen-browser.zen")?.appleScript,
                     "Zen has no dictionary: ignored")
        XCTAssertNil(onMonitor.sitePolicyCalls.last?.request(for: "com.apple.Safari")?.appleScript, "not allowed")
    }
}
