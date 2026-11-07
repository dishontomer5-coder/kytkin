// P3-14: the wiring decisions above ContextMonitor, with fakes: AppController builds and pushes the SitePolicy
// (before the monitor starts; on Pause, Kytkin off, Accessibility, browser preferences), exposes BrowserSupport for
// P3-15; a site read only from the Gecko address bar is applied but never learned (P3-20 decision); and the P3-19
// items: no KeyWatcher reset on `.page` ↔ `.unknown`, the fight re-assert kept across page-state-only changes.
// Also the Core pieces: ContextAssembler's bar flag and `browserUnwatched`, and `hasSameFacts` with the bar flag.

import XCTest

@MainActor
final class SiteWiringTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var permissions: FakePermissions!
    private var watcher: FakeKeyWatcher!
    private var store: PreferencesStore!
    private var sut: AppController!
    private let zen = "app.zen-browser.zen"
    private let other = "com.example.OtherBrowser"
    private let date = Date(timeIntervalSince1970: 5_000)
    private var generation: UInt64 = 100

    private func make(_ prefs: Preferences = Preferences(), accessibility: PermissionState = .granted,
                      suffixListLoaded: Bool = true) {
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: IDs.abc)
        monitor = FakeContextMonitor()
        permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: accessibility,
                                                                             inputMonitoring: .granted))
        watcher = FakeKeyWatcher()
        store = makeStore(prefs, clock: clock)
        sut = AppController(switcher: switcher, context: monitor, store: store, permissions: permissions,
                            conflicts: FakeConflicts(), keyWatcher: watcher, ticker: FakeTicker(), clock: clock,
                            now: { [date] in date }, suffixListLoaded: suffixListLoaded,
                            webLinkHandlers: { [other, zen] in [other, zen] })
        switcher.onChange = { [unowned self] in self.sut.inputSourceDidChange($0) }
        monitor.onChange = { [unowned self] in self.sut.contextDidChange($0) }
        permissions.onChange = { [unowned self] in self.sut.permissionsDidChange($0) }
        sut.start()
    }

    /// The browser reports a page, as ContextAssembler would emit it.
    @discardableResult
    private func show(domain: String? = "ynet.co.il", page: BrowserPageState? = .page, bar: Bool = false,
                      pid: Int32 = 7) -> Context {
        generation += 1
        let c = Context(bundleID: zen, pid: pid, host: domain.map { "www.\($0)" }, siteDomain: domain,
                        pageState: page, readFromAddressBar: bar, generation: generation)
        monitor.current = c
        monitor.onChange?(c)
        return c
    }

    private func userSwitch(to id: InputSourceID) {
        clock.advance(byMilliseconds: 600)
        switcher.current = id
        sut.inputSourceDidChange(.external(id, atNanos: clock.nowNanos))
    }

    private func twoWords() {
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
    }

    private func site(_ domain: String, _ source: InputSourceID) -> Rule {
        Rule(scope: .site(domain: domain), inputSource: source, origin: .learned, updatedAt: date)
    }

    // MARK: - SitePolicy from AppController

    func testPolicyIsPushedBeforeTheMonitorStarts() throws {
        make()
        let atStart = try XCTUnwrap(monitor.policyAtStart ?? nil, "the launch's browser gets its site grace")
        XCTAssertNotNil(atStart.request(for: zen))
        XCTAssertNotNil(atStart.request(for: other), "a web-link handler is a best-effort browser")
        XCTAssertNil(atStart.request(for: "com.apple.Notes"))
        XCTAssertEqual(sut.otherBrowserBundleIDs, [other])
    }

    func testMissingSuffixListWatchesNothing() throws {
        make(suffixListLoaded: false)
        XCTAssertNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen))
        XCTAssertEqual(sut.browserSupport(for: zen), .siteDataMissing)
    }

    func testNoAccessibilityWatchesNothingUntilGranted() throws {
        make(accessibility: .denied)
        XCTAssertNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen))
        XCTAssertEqual(sut.browserSupport(for: zen), .needsAccessibility)
        permissions.grant(accessibility: .granted, inputMonitoring: .granted)
        XCTAssertNotNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen), "a grant re-attaches")
        XCTAssertEqual(sut.browserSupport(for: zen), .notSeenYet)
    }

    func testPauseAndResumeChangeThePolicy() throws {
        make()
        let before = monitor.sitePolicyCalls.count
        sut.setPaused(true)
        XCTAssertNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen), "paused: nothing watched")
        sut.setPaused(false)
        XCTAssertNotNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen))
        XCTAssertEqual(monitor.sitePolicyCalls.count, before + 2)
    }

    func testBrowserPreferencesChangeThePolicyOnlyWhenTheyChange() throws {
        make()
        let before = monitor.sitePolicyCalls.count
        store.update { $0.rules.append(.app("com.apple.Notes", IDs.hebrew)) }
        sut.preferencesDidChange()
        XCTAssertEqual(monitor.sitePolicyCalls.count, before, "rules don't change the policy")
        store.update { $0.browsers.siteRulesEnabled[zen] = false }
        sut.preferencesDidChange()
        XCTAssertNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: zen))
        store.update { $0.browsers.ignorePrivateWindowsCompletely = true }
        sut.preferencesDidChange()
        XCTAssertEqual(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: other)?.ignorePrivateWindows, true)
        store.update { $0.general.enabled = false }
        sut.preferencesDidChange()
        XCTAssertNil(try XCTUnwrap(monitor.sitePolicyCalls.last).request(for: other), "Kytkin off")
    }

    func testBrowserSupportComesFromTheMonitorsTracker() {
        make()
        XCTAssertEqual(sut.browserSupport(for: zen), .notSeenYet)
        monitor.browserSupport.record(bundleID: zen, BrowserObservation(site: nil, pageState: .notWebPage,
                                                                        isPrivate: nil, via: .axURL),
                                      sawWindow: true)
        XCTAssertEqual(sut.browserSupport(for: zen), .works)
        store.update { $0.browsers.siteRulesEnabled[zen] = false }
        sut.preferencesDidChange()
        XCTAssertEqual(sut.browserSupport(for: zen), .off)
    }

    func testDebugMenuCarriesTheSiteLine() {
        make()
        #if DEBUG
        XCTAssertEqual(sut.menuState.siteDebug, "Sites: fake")
        #else
        XCTAssertNil(sut.menuState.siteDebug)
        #endif
    }

    // MARK: - P3-20 decision: Gecko bar sites apply, never learn

    func testBarSiteAppliesItsRule() {
        var p = Preferences()
        p.rules = [site("ynet.co.il", IDs.hebrew)]
        make(p)
        show(bar: true)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testBarSiteIsNeverLearned() {
        make()
        show(bar: true)
        userSwitch(to: IDs.hebrew)
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty, "nothing learned: not the site, not the browser")
        XCTAssertTrue(sut.switching.learnerDebug.contains("siteFromAddressBar"), sut.switching.learnerDebug)
    }

    func testTheSameSiteFromAXURLIsLearned() {
        make()
        show(bar: true)
        clock.advance(byMilliseconds: 600)
        show(bar: false)                       // focus back in the page: AXURL confirms the site
        userSwitch(to: IDs.hebrew)
        twoWords()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.site(domain: "ynet.co.il")])
    }

    func testBarFlagChangeDoesNotReapplyTheRule() {
        var p = Preferences()
        p.rules = [site("ynet.co.il", IDs.hebrew)]
        make(p)
        show()
        userSwitch(to: IDs.abc)                // the user's own choice
        show(bar: true)                        // focus left the page (toolbar): read from the bar
        show(bar: false)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "the manual switch is not undone")
    }

    func testLearnerDiscardsBarContexts() {
        let sec: UInt64 = 1_000_000_000
        var l = RuleLearner(engine: RuleEngine(rules: []), keyboardTapAvailable: true, currentSource: IDs.abc)
        let c = Context(bundleID: zen, pid: 7, host: "ynet.co", siteDomain: "ynet.co", pageState: .page,
                        readFromAddressBar: true, generation: 1)
        XCTAssertNil(l.handle(.contextChanged(c, atNanos: 10 * sec)))
        XCTAssertEqual(l.handle(.externalSwitch(IDs.hebrew, atNanos: 12 * sec)), .discard(.siteFromAddressBar))
        // A `.notWebPage` answer from the bar isn't learned at app level either.
        let notWeb = Context(bundleID: zen, pid: 7, pageState: .notWebPage, readFromAddressBar: true, generation: 2)
        XCTAssertNil(l.handle(.contextChanged(notWeb, atNanos: 13 * sec)))
        XCTAssertEqual(l.handle(.externalSwitch(IDs.russian, atNanos: 15 * sec)), .discard(.siteFromAddressBar))
    }

    /// QA (P3-14): the flag can't be laundered. A switch made on an AXURL site, then a bar read of another site
    /// (half-typed text), learns nothing for either; a switch on the bar site, then AXURL of a different site, neither.
    func testABarReadOfAnotherSiteIsNeverLearned() {
        make()
        show()                                                     // ynet from AXURL
        userSwitch(to: IDs.hebrew)                                 // candidate for ynet
        show(domain: "ynet.co", bar: true)                         // the bar holds half-typed text
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty, "the candidate died with the context change")
        userSwitch(to: IDs.abc)                                    // a switch while the bar site is shown
        show(domain: "haaretz.co.il")                              // AXURL lands on another site
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty, "\(store.prefs.rules)")
        userSwitch(to: IDs.hebrew)                                 // now a real AXURL site: learnable
        twoWords()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.site(domain: "haaretz.co.il")])
    }

    func testABarReadMidCandidateCancelsIt() {
        make()
        show()
        userSwitch(to: IDs.hebrew)
        sut.keySignal(.wordBoundary)
        show(bar: true)                                            // same site, now only from the bar
        sut.keySignal(.wordBoundary)
        sut.keySignal(.wordBoundary)
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    // MARK: - QA (P3-14): Resume / turn-on in a browser switches once

    private func siteAndAppRules() -> Preferences {
        var p = Preferences()
        p.rules = [.app(zen, IDs.russian), site("ynet.co.il", IDs.hebrew)]
        return p
    }

    func testResumeInABrowserWaitsForTheSiteAndSwitchesOnce() {
        make(siteAndAppRules())
        monitor.awaitSiteOnPolicy = zen
        show()
        sut.setPaused(true)
        show(domain: nil, page: nil)                               // not watched while paused: site dropped
        switcher.current = IDs.abc
        let before = switcher.selectedIDs
        sut.setPaused(false)
        XCTAssertTrue(monitor.isAwaitingSite, "the policy went out before the re-apply")
        XCTAssertEqual(switcher.selectedIDs, before, "not the browser's rule while the read is pending")
        monitor.isAwaitingSite = false
        show()
        XCTAssertEqual(switcher.selectedIDs, before + [IDs.hebrew])
    }

    func testResumeHoldRunningOutAppliesTheBrowsersRule() {
        make(siteAndAppRules())
        monitor.awaitSiteOnPolicy = zen
        show()
        sut.setPaused(true)
        show(domain: nil, page: nil)
        switcher.current = IDs.abc
        let before = switcher.selectedIDs
        sut.setPaused(false)
        monitor.isAwaitingSite = false
        show(domain: nil, page: .unknown)                          // grace ran out: nil → .unknown, page state only
        XCTAssertEqual(switcher.selectedIDs, before + [IDs.russian], "the deferred re-apply still happens")
    }

    func testResumeWithoutAHoldAppliesAtOnce() {
        make(siteAndAppRules())
        show()
        sut.setPaused(true)
        switcher.current = IDs.abc
        let before = switcher.selectedIDs
        sut.setPaused(false)
        XCTAssertEqual(switcher.selectedIDs, before + [IDs.hebrew])
    }

    func testPausingAgainDropsTheDeferredReapply() {
        make(siteAndAppRules())
        monitor.awaitSiteOnPolicy = zen
        show()
        sut.setPaused(true)
        show(domain: nil, page: nil)
        switcher.current = IDs.abc
        let before = switcher.selectedIDs
        sut.setPaused(false)
        sut.setPaused(true)
        monitor.isAwaitingSite = false
        show()
        XCTAssertEqual(switcher.selectedIDs, before, "paused: nothing")
    }

    func testTurningKytkinOnInABrowserWaitsForTheSite() {
        make(siteAndAppRules())
        monitor.awaitSiteOnPolicy = zen
        show()
        store.update { $0.general.enabled = false }
        sut.preferencesDidChange()
        show(domain: nil, page: nil)
        switcher.current = IDs.abc
        let before = switcher.selectedIDs
        store.update { $0.general.enabled = true }
        sut.preferencesDidChange()
        XCTAssertTrue(monitor.isAwaitingSite)
        XCTAssertEqual(switcher.selectedIDs, before)
        monitor.isAwaitingSite = false
        show()
        XCTAssertEqual(switcher.selectedIDs, before + [IDs.hebrew])
    }

    func testResumePushesThePolicyOnce() {
        make()
        sut.setPaused(true)
        let before = monitor.sitePolicyCalls.count
        sut.setPaused(false)
        XCTAssertEqual(monitor.sitePolicyCalls.count, before + 1, "pushed early, not again by recompute")
    }

    // MARK: - P3-19: KeyWatcher reset and the fight re-assert

    func testPageUnknownFlipsKeepTheWordBuffer() {
        make()
        show()
        watcher.clear()
        show(page: .unknown)                   // one AX timeout
        show(page: .page)
        show(bar: true)                        // same site, another source
        XCTAssertFalse(watcher.calls.contains(.perform(.reset(.contextChange))), "\(watcher.calls)")
        XCTAssertTrue(watcher.calls.contains(.checkSecureInput))
    }

    func testAddressBarStillResetsTheWordBuffer() {
        make()
        show()
        watcher.clear()
        show(page: .editingAddress)
        XCTAssertEqual(watcher.calls.filter { $0 == .perform(.reset(.contextChange)) }.count, 1)
        show(page: .page)
        XCTAssertEqual(watcher.calls.filter { $0 == .perform(.reset(.contextChange)) }.count, 2)
    }

    func testASiteChangeStillResetsTheWordBuffer() {
        make()
        show()
        watcher.clear()
        show(domain: "haaretz.co.il")
        XCTAssertEqual(watcher.calls.first, .perform(.reset(.contextChange)))
    }

    func testKeepsWordBufferOnlyForQuietPageStateChanges() {
        XCTAssertFalse(AppController.keepsWordBuffer(.full))
        XCTAssertTrue(AppController.keepsWordBuffer(.pageStateOnly(from: .page, to: .unknown)))
        XCTAssertTrue(AppController.keepsWordBuffer(.pageStateOnly(from: .unknown, to: .page)))
        XCTAssertTrue(AppController.keepsWordBuffer(.pageStateOnly(from: .page, to: .page)))
        XCTAssertFalse(AppController.keepsWordBuffer(.pageStateOnly(from: .page, to: .editingAddress)))
        XCTAssertFalse(AppController.keepsWordBuffer(.pageStateOnly(from: .editingAddress, to: .page)))
        XCTAssertFalse(AppController.keepsWordBuffer(.pageStateOnly(from: .notWebPage, to: .unknown)))
    }

    func testFightReassertSurvivesAPageStateOnlyChange() {
        var p = Preferences()
        p.rules = [site("ynet.co.il", IDs.hebrew)]
        make(p)
        show()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        clock.advance(byMilliseconds: 20)
        show(page: .unknown)                   // a read lands right after the switch
        clock.advance(byMilliseconds: 30)
        switcher.current = IDs.abc             // another switcher puts ABC back
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew], "re-asserted once")
        clock.advance(byMilliseconds: 20)
        show(page: .page)
        clock.advance(byMilliseconds: 20)
        switcher.current = IDs.abc
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos))
        XCTAssertEqual(switcher.selectedIDs.count, 2, "still only once")
    }

    // MARK: - Core: ContextAssembler and BrowserObservation

    func testAssemblerCountsTheBarFlagAndUnwatches() throws {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        var a = ContextAssembler(clock: clock, ownPID: 999, ownBundleID: nil)
        let ynet = SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 7, awaitsSite: true))
        let first = try XCTUnwrap(a.browserObserved(BrowserObservation(site: ynet, pageState: .page, isPrivate: nil,
                                                                       via: .addressBar), pid: 7))
        XCTAssertTrue(first.readFromAddressBar)
        clock.advance(byMilliseconds: 500)
        let second = try XCTUnwrap(a.browserObserved(BrowserObservation(site: ynet, pageState: .page, isPrivate: nil,
                                                                        via: .axURL), pid: 7))
        XCTAssertFalse(second.readFromAddressBar)
        XCTAssertNil(a.browserObserved(BrowserObservation(site: ynet, pageState: .page, isPrivate: nil, via: .kept),
                                       pid: 7), "kept vs AXURL: not the bar either way, no change")
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(a.browserUnwatched(pid: 8), "stale pid")
        let gone = try XCTUnwrap(a.browserUnwatched(pid: 7))
        XCTAssertNil(gone.siteDomain)
        XCTAssertNil(gone.host)
        XCTAssertNil(gone.pageState)
        XCTAssertNil(a.browserUnwatched(pid: 7), "nothing left to drop")
    }

    func testUnwatchingDuringTheGraceEmitsTheAppAtOnce() throws {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        var a = ContextAssembler(clock: clock, ownPID: 999, ownBundleID: nil)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 7, awaitsSite: true))
        let c = try XCTUnwrap(a.browserUnwatched(pid: 7))
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertNil(c.pageState, "not watched: no page state (not `.unknown`)")
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    /// QA (P3-14): `awaitSite` holds only the newest app, only while it has no page state (not watched yet).
    func testAwaitSiteGuards() throws {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        var a = ContextAssembler(clock: clock, ownPID: 999, ownBundleID: nil)
        let ynet = SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true)
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 7))
        a.awaitSite(pid: 8)
        XCTAssertFalse(a.isAwaitingSite, "stale pid")
        a.awaitSite(pid: 7)
        XCTAssertTrue(a.isAwaitingSite)
        let c = try XCTUnwrap(a.browserObserved(BrowserObservation(site: ynet, pageState: .page, isPrivate: nil,
                                                                   via: .axURL), pid: 7), "released by the read")
        XCTAssertEqual(c.siteDomain, "ynet.co.il")
        XCTAssertFalse(a.isAwaitingSite)
        a.awaitSite(pid: 7)
        XCTAssertFalse(a.isAwaitingSite, "already has a page state: nothing to wait for")
    }

    func testSameFactsIncludeTheBarFlag() {
        let ynet = SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true)
        let bar = BrowserObservation(site: ynet, pageState: .page, isPrivate: nil, via: .addressBar)
        let ax = BrowserObservation(site: ynet, pageState: .page, isPrivate: nil, via: .axURL)
        let kept = BrowserObservation(site: ynet, pageState: .page, isPrivate: nil, via: .kept)
        XCTAssertFalse(bar.hasSameFacts(as: ax), "the engine posts bar → AXURL")
        XCTAssertTrue(ax.hasSameFacts(as: kept))
    }
}
