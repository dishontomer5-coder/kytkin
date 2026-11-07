// P3-14: ContextMonitor tier 1 (001 §14.5) with a fake source and a fake `BrowserWatching`: attach on a watched
// browser's activation with the site grace, detach on other apps and on Kytkin, a policy change re-attaches or
// detaches (and drops stale site fields), stale attachIDs, wake, session resign, stop and deinit, the support
// tracker, and the Gecko-bar flag reaching the Context. Nothing here touches a real app or the AX API.

import XCTest

@MainActor final class FakeBrowserWatcher: BrowserWatching {
    enum Call: Equatable {
        case attach(Int32, String, BrowserWatchRequest)
        case detach
        case wake
    }
    var onObservation: (@MainActor (_ pid: Int32, _ attachID: UInt64, BrowserObservation, _ sawWindow: Bool) -> Void)?
    private(set) var calls: [Call] = []
    private var current: (pid: Int32, request: BrowserWatchRequest, id: UInt64)?
    private var lastID: UInt64 = 0
    var attachID: UInt64? { current?.id }

    @discardableResult func attach(pid: Int32, bundleID: String, request: BrowserWatchRequest) -> UInt64 {
        calls.append(.attach(pid, bundleID, request))
        if let current, current.pid == pid, current.request == request { return current.id }
        lastID += 1
        current = (pid, request, lastID)
        return lastID
    }
    func detach() {
        calls.append(.detach)
        current = nil
    }
    func wake() { calls.append(.wake) }
    func clear() { calls = [] }

    /// A read result for the current attach (or `attachID`), as the real watcher posts it on main.
    func post(_ o: BrowserObservation, pid: Int32, attachID: UInt64? = nil, sawWindow: Bool = true) {
        onObservation?(pid, attachID ?? current?.id ?? 0, o, sawWindow)
    }
}

@MainActor
final class ContextMonitorBrowserTests: XCTestCase {
    private final class FakeSource: AppActivationSource {
        var onActivate: (@MainActor (String, Int32) -> Void)?
        var onTerminate: (@MainActor (Int32) -> Void)?
        var onWake: (@MainActor () -> Void)?
        var onSessionResign: (@MainActor () -> Void)?
        var stopped = 0
        func start() {}
        func stop() { stopped += 1 }
    }

    private let zen = "app.zen-browser.zen"
    private let chrome = "com.google.Chrome"
    private let notes = "com.apple.Notes"
    private let own = "io.github.kytkin.Kytkin.dev"
    private var clock: FakeClock!
    private var source: FakeSource!
    private var browsers: FakeBrowserWatcher!
    private var monitor: ContextMonitor!
    private var seen: [Context] = []

    private let ynet = SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true)

    private func make() {
        clock = FakeClock(nowNanos: 1_000_000_000)
        source = FakeSource()
        browsers = FakeBrowserWatcher()
        seen = []
        monitor = ContextMonitor(source: source, browsers: browsers, clock: clock, ownPID: 999, ownBundleID: own)
        monitor.onChange = { [unowned self] in seen.append($0) }
        monitor.start()
    }


    private func policy(siteRules: Bool = true, on: Bool = true, ignorePrivate: Bool = false,
                        suffixListLoaded: Bool = true, siteRulesOn: Bool = true,
                        handlers: Set<String> = []) -> SitePolicy {
        var b = Preferences.Browsers()
        b.ignorePrivateWindowsCompletely = ignorePrivate
        b.siteRulesOn = siteRulesOn   // P3-26: one global switch
        return SitePolicy(availability: browserAvailability(on: on, siteRules: siteRules), browsers: b,
                          suffixListLoaded: suffixListLoaded, webLinkHandlers: handlers,
                          ownBundleIDPrefix: KnownSwitchers.ownBundleIDPrefix)
    }

    private func page(_ site: SiteAddress? = nil, _ state: BrowserPageState = .page, private isPrivate: Bool? = nil,
                      via: BrowserObservation.Via = .axURL) -> BrowserObservation {
        BrowserObservation(site: site ?? ynet, pageState: state, isPrivate: isPrivate, via: via)
    }

    private var zenRequest: BrowserWatchRequest { policy().request(for: zen)! }

    // MARK: - Attach / detach on activation

    func testNothingIsWatchedBeforeAPolicyArrives() {
        make()
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [], "no policy yet: no attach (and nothing to detach)")
        XCTAssertEqual(seen.map(\.bundleID), [zen], "no grace: emitted at once")
        XCTAssertNil(seen.last?.pageState)
    }

    func testBrowserActivationAttachesAndWaitsForTheFirstRead() throws {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [.attach(20, zen, zenRequest)])
        XCTAssertTrue(seen.isEmpty, "the site grace holds the activation (D4)")
        browsers.post(page(), pid: 20)
        let c = try XCTUnwrap(seen.last)
        XCTAssertEqual(seen.count, 1, "one Context, app and site together")
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertEqual(c.siteDomain, "ynet.co.il")
        XCTAssertEqual(c.pageState, .page)
        XCTAssertFalse(c.readFromAddressBar)
    }

    func testGraceRunsOutAppOnly() throws {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        clock.advance(byMilliseconds: 200)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let c = try XCTUnwrap(seen.last)
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertEqual(c.pageState, .unknown)
        XCTAssertNil(c.siteDomain)
    }

    func testOtherAppDetaches() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        browsers.clear()
        clock.advance(byMilliseconds: 500)
        source.onActivate?(notes, 30)
        XCTAssertEqual(browsers.calls, [.detach])
        XCTAssertEqual(seen.last?.bundleID, notes)
        XCTAssertNil(seen.last?.pageState)
    }

    func testKytkinInFrontDetachesAndKeepsTheBrowsersContext() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        browsers.clear()
        source.onActivate?(own, 999)
        XCTAssertEqual(browsers.calls, [.detach], "Kytkin's own window: no AX work (§14.1)")
        XCTAssertEqual(seen.count, 1, "Kytkin is not a context")
        // Back to Zen: a fresh attach (the watcher was detached) and a read; same app → no new Context by itself.
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [.detach, .attach(20, zen, zenRequest)])
        XCTAssertEqual(seen.count, 1)
        browsers.post(page(), pid: 20)
        XCTAssertEqual(seen.count, 1, "the same site: nothing changed")
    }

    func testDuplicateActivationOfTheWatchedBrowserRereads() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        source.onActivate?(zen, 20)   // a Space change re-reports the frontmost app
        XCTAssertEqual(browsers.calls, [.attach(20, zen, zenRequest), .attach(20, zen, zenRequest)],
                       "the watcher turns the same request into a read")
    }

    func testBrowserWithSiteRulesOffIsNotWatched() {
        make()
        monitor.setSitePolicy(policy(siteRulesOn: false))
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [])
        XCTAssertEqual(seen.last?.bundleID, zen)
    }

    // MARK: - Policy changes

    func testPolicyChangeReattachesWithTheNewRequest() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        browsers.clear()
        monitor.setSitePolicy(policy(ignorePrivate: true))
        let request = policy(ignorePrivate: true).request(for: zen)!
        XCTAssertEqual(browsers.calls, [.attach(20, zen, request)])
    }

    func testTheSamePolicyOrTheSameRequestChangesNothing() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.clear()
        monitor.setSitePolicy(policy())
        // Another part of the policy changed (a new web-link handler): Zen's request is unchanged, so no re-read.
        monitor.setSitePolicy(policy(handlers: ["com.example.NewBrowser"]))
        XCTAssertEqual(browsers.calls, [])
    }

    func testPolicyTurningSitesOffDetachesAndDropsTheSite() throws {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        browsers.clear()
        clock.advance(byMilliseconds: 500)
        monitor.setSitePolicy(policy(siteRules: false))   // Accessibility revoked, or Kytkin paused/off
        XCTAssertEqual(browsers.calls, [.detach])
        let c = try XCTUnwrap(seen.last)
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertNil(c.siteDomain, "the browser's own rule applies again")
        XCTAssertNil(c.pageState)
    }

    func testMissingSuffixListMeansNoWatching() {
        make()
        monitor.setSitePolicy(policy(suffixListLoaded: false))   // D11
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [])
    }

    func testPolicyTurningSitesOnAttachesTheBrowserInFront() throws {
        make()
        monitor.setSitePolicy(policy(siteRules: false))
        source.onActivate?(zen, 20)
        XCTAssertEqual(browsers.calls, [])
        clock.advance(byMilliseconds: 500)
        monitor.setSitePolicy(policy())
        XCTAssertEqual(browsers.calls, [.attach(20, zen, zenRequest)])
        browsers.post(page(), pid: 20)
        XCTAssertEqual(try XCTUnwrap(seen.last).siteDomain, "ynet.co.il")
    }

    /// QA (P3-14): Resume / turned on / a grant with the browser in front: the next Context waits for the first read
    /// (one switch with the site, not the browser's rule first).
    func testPolicyTurningSitesOnHoldsTheBrowserForItsFirstRead() throws {
        make()
        monitor.setSitePolicy(policy(siteRules: false))
        source.onActivate?(zen, 20)
        XCTAssertEqual(seen.count, 1)
        XCTAssertFalse(monitor.isAwaitingSite)
        clock.advance(byMilliseconds: 500)
        monitor.setSitePolicy(policy())
        XCTAssertTrue(monitor.isAwaitingSite)
        XCTAssertEqual(seen.count, 1)
        browsers.post(page(), pid: 20)
        XCTAssertFalse(monitor.isAwaitingSite)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(try XCTUnwrap(seen.last).siteDomain, "ynet.co.il")
        XCTAssertEqual(try XCTUnwrap(seen.last).pageState, .page)
    }

    func testHoldAfterAPolicyChangeRunsOutAppOnly() throws {
        make()
        monitor.setSitePolicy(policy(siteRules: false))
        source.onActivate?(zen, 20)
        clock.advance(byMilliseconds: 500)
        monitor.setSitePolicy(policy())
        clock.advance(byMilliseconds: 200)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(monitor.isAwaitingSite)
        XCTAssertEqual(seen.count, 2)
        let c = try XCTUnwrap(seen.last)
        XCTAssertEqual(c.pageState, .unknown, "app-only: SwitchController applies the browser's rule")
        XCTAssertNil(c.siteDomain)
    }

    func testANewRequestForTheWatchedBrowserDoesNotHold() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        monitor.setSitePolicy(policy(ignorePrivate: true))
        XCTAssertFalse(monitor.isAwaitingSite, "already watched: the site is known, nothing to wait for")
    }

    func testPolicyTurningSitesOnWhileKytkinIsInFrontAttachesNothing() {
        make()
        monitor.setSitePolicy(policy(siteRules: false))
        source.onActivate?(zen, 20)
        source.onActivate?(own, 999)                                // Settings in front (W2)
        monitor.setSitePolicy(policy())
        XCTAssertEqual(browsers.calls, [])
        XCTAssertFalse(monitor.isAwaitingSite)
        source.onActivate?(zen, 20)                                 // back to Zen: attached now
        XCTAssertEqual(browsers.calls, [.attach(20, zen, zenRequest)])
    }

    /// QA (P3-14): the watched browser quits or crashes: detach at once (no observer or poll on a dead pid).
    func testWatchedBrowserQuittingDetaches() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        let id = browsers.attachID
        browsers.post(page(), pid: 20)
        browsers.clear()
        source.onTerminate?(31)                                      // another app quit
        XCTAssertEqual(browsers.calls, [])
        source.onTerminate?(20)
        XCTAssertEqual(browsers.calls, [.detach])
        let count = seen.count
        let other = SiteAddress(host: "haaretz.co.il", registrableDomain: "haaretz.co.il", isWebPage: true)
        browsers.post(page(other), pid: 20, attachID: id)           // a read that was in flight
        XCTAssertEqual(seen.count, count, "dropped")
        monitor.setSitePolicy(policy(ignorePrivate: true))
        XCTAssertEqual(browsers.calls, [.detach], "a dead browser is not re-attached by a policy change")
    }

    func testSiteRulesTurnedOffWhileKytkinIsInFrontDropTheSiteOnReturn() throws {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        source.onActivate?(own, 999)                                // Settings in front
        monitor.setSitePolicy(policy(siteRulesOn: false))
        clock.advance(byMilliseconds: 500)
        source.onActivate?(zen, 20)                                 // back to Zen
        let c = try XCTUnwrap(seen.last)
        XCTAssertNil(c.siteDomain)
        XCTAssertNil(c.pageState)
    }

    // MARK: - Observations

    func testStaleAttachIDIsDropped() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        let first = browsers.attachID
        browsers.post(page(), pid: 20)
        monitor.setSitePolicy(policy(ignorePrivate: true))          // a new attach
        XCTAssertNotEqual(browsers.attachID, first)
        let count = seen.count
        let other = SiteAddress(host: "haaretz.co.il", registrableDomain: "haaretz.co.il", isWebPage: true)
        browsers.post(page(other), pid: 20, attachID: first)
        browsers.post(page(other), pid: 21)
        XCTAssertEqual(seen.count, count)
    }

    func testGeckoBarSiteReachesTheContextAsAFlag() throws {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(via: .addressBar), pid: 20)
        let c = try XCTUnwrap(seen.last)
        XCTAssertTrue(c.readFromAddressBar)
        XCTAssertEqual(c.siteDomain, "ynet.co.il")
        clock.advance(byMilliseconds: 500)
        browsers.post(page(via: .axURL), pid: 20)
        XCTAssertEqual(seen.count, 2, "bar → AXURL on the same site is a change (it may be learned now)")
        XCTAssertFalse(try XCTUnwrap(seen.last).readFromAddressBar)
    }

    func testSupportTrackerRecordsReadsWithTheWindowFlag() {
        make()
        monitor.setSitePolicy(policy())
        let request = policy().request(for: zen)
        func status() -> BrowserSupport {
            monitor.browserSupport.status(bundleID: zen, request: request, availability: browserAvailability(),
                                          suffixListLoaded: true)
        }
        source.onActivate?(zen, 20)
        XCTAssertEqual(status(), .notSeenYet)
        for _ in 0..<5 { browsers.post(.unknown(), pid: 20, sawWindow: false) }
        XCTAssertEqual(status(), .notSeenYet, "no window: says nothing about support")
        for _ in 0..<3 { browsers.post(.unknown(), pid: 20, sawWindow: true) }
        XCTAssertEqual(status(), .cantRead)
        browsers.post(page(), pid: 20)
        XCTAssertEqual(status(), .works)
    }

    func testSiteDebugNamesNoHost() {
        make()
        XCTAssertEqual(monitor.siteDebug, "Sites: not watching")
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(private: true), pid: 20)
        let line = monitor.siteDebug
        XCTAssertTrue(line.contains("gecko"), line)
        XCTAssertTrue(line.contains("1 updates"), line)
        XCTAssertTrue(line.contains("page via axURL, private"), line)
        XCTAssertFalse(line.contains("ynet"), line)
    }

    // MARK: - Wake, session, stop, deinit

    func testWakeRereadsTheWatchedBrowser() {
        make()
        monitor.setSitePolicy(policy())
        source.onWake?()
        XCTAssertEqual(browsers.calls, [], "nothing watched: no wake")
        source.onActivate?(zen, 20)
        browsers.clear()
        source.onWake?()
        XCTAssertEqual(browsers.calls, [.wake])
    }

    func testSessionResignDetachesAndTheNextActivationReattaches() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.post(page(), pid: 20)
        browsers.clear()
        source.onSessionResign?()
        XCTAssertEqual(browsers.calls, [.detach])
        monitor.setSitePolicy(policy(ignorePrivate: true))
        XCTAssertEqual(browsers.calls, [.detach], "nothing is attached while another session is in front")
        XCTAssertEqual(seen.last?.siteDomain, "ynet.co.il", "the site isn't dropped meanwhile")
        // Session back: the source re-reports the frontmost app, then wakes.
        source.onActivate?(zen, 20)
        source.onWake?()
        let request = policy(ignorePrivate: true).request(for: zen)!
        XCTAssertEqual(browsers.calls, [.detach, .attach(20, zen, request), .wake])
    }

    func testStopDetaches() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.clear()
        monitor.stop()
        XCTAssertEqual(browsers.calls, [.detach])
        XCTAssertNil(browsers.onObservation)
    }

    func testReleasedMonitorDetachesTheWatcher() {
        make()
        monitor.setSitePolicy(policy())
        source.onActivate?(zen, 20)
        browsers.clear()
        weak var weakMonitor = monitor
        monitor = nil
        XCTAssertNil(weakMonitor)
        XCTAssertEqual(browsers.calls, [.detach], "the isolated deinit detaches the watcher")
        XCTAssertNil(browsers.onObservation)
    }

    func testReleasedMonitorWithNothingWatchedDoesNotDetach() {
        make()
        source.onActivate?(notes, 30)
        monitor = nil
        XCTAssertEqual(browsers.calls, [])
    }
}
