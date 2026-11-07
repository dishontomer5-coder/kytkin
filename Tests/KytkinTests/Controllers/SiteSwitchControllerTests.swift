// P3-9: SwitchController on sites (001 §14.6): page-state-only changes cancel learning but don't re-apply rules (D5),
// a site rule beats a pinned browser, learning on a site vs the app, Pin in a private window (owner Q1), Forget on a
// site acts only on a site or siteHost rule (D6), Punycode storage, and the DEBUG learner line without the domain.

import XCTest

@MainActor
final class SiteSwitchControllerTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var store: PreferencesStore!
    private var sut: SwitchController!
    private let zen = "app.zen-browser.zen"
    private let date = Date(timeIntervalSince1970: 5_000)
    private var generation: UInt64 = 100

    private func make(_ rules: [Rule] = [], current: InputSourceID = IDs.abc) {
        var p = Preferences()
        p.rules = rules
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: current)
        monitor = FakeContextMonitor()
        store = makeStore(p, clock: clock)
        sut = SwitchController(switcher: switcher, context: monitor, store: store, conflicts: FakeConflicts(),
                               clock: clock, now: { [date] in date })
        sut.setKeyboardTapAvailable(true)
    }

    /// The browser reports a page (a new Context, as ContextAssembler would emit it).
    @discardableResult
    private func show(host: String? = "www.ynet.co.il", domain: String? = "ynet.co.il", private isPrivate: Bool? = nil,
                      page: BrowserPageState? = .page, pid: Int32 = 7) -> Context {
        generation += 1
        let c = Context(bundleID: zen, pid: pid, host: host, siteDomain: domain, isPrivateWindow: isPrivate,
                        pageState: page, generation: generation)
        monitor.current = c
        sut.contextDidChange(c)
        return c
    }

    private func userSwitch(to id: InputSourceID) {
        clock.advance(byMilliseconds: 600)
        switcher.current = id
        sut.inputSourceDidChange(.external(id, atNanos: clock.nowNanos))
    }

    private func twoWords() {
        sut.wordBoundary()
        sut.wordBoundary()
    }

    private func site(_ domain: String, _ source: InputSourceID, _ origin: RuleOrigin = .learned) -> Rule {
        Rule(scope: .site(domain: domain), inputSource: source, origin: origin, updatedAt: date)
    }

    private func host(_ host: String, _ source: InputSourceID, _ origin: RuleOrigin = .pinned) -> Rule {
        Rule(scope: .siteHost(host: host), inputSource: source, origin: origin, updatedAt: date)
    }

    // MARK: - Site beats the browser pin

    func testSiteRuleBeatsAPinnedBrowser() {
        make([.app(zen, IDs.russian, .pinned), site("ynet.co.il", IDs.hebrew)])
        show()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        show(host: "www.haaretz.co.il", domain: "haaretz.co.il")
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian], "the browser pin is the default elsewhere")
    }

    // MARK: - D5: page-state-only changes

    func testPageStateOnlyChangeDoesNotReapplyTheRule() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        userSwitch(to: IDs.abc)                       // the user's own choice on this page
        show(page: .editingAddress)                   // clicks into the address bar
        show(page: .page)                             // and back into the page
        show(page: .unknown)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "the manual switch is not undone")
        XCTAssertEqual(switcher.current, IDs.abc)
    }

    func testPageStateOnlyChangeCancelsTheCandidate() {
        make()
        show()
        userSwitch(to: IDs.hebrew)
        XCTAssertNotNil(sut.learner.pending)
        show(page: .editingAddress)
        XCTAssertNil(sut.learner.pending, "typing in the address bar must not confirm the page's candidate")
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testPageStateOnlyChangeRestartsTheSettle() {
        make()
        show()
        show(page: .editingAddress)
        show(page: .page)
        clock.advance(byMilliseconds: 100)
        switcher.current = IDs.hebrew
        sut.inputSourceDidChange(.external(IDs.hebrew, atNanos: clock.nowNanos))
        XCTAssertNil(sut.learner.pending, "within the settle after the page-state change")
    }

    func testASiteChangeStillAppliesItsRule() {
        make([site("ynet.co.il", IDs.hebrew), site("haaretz.co.il", IDs.russian)])
        show()
        show(page: .editingAddress)
        show(host: "www.haaretz.co.il", domain: "haaretz.co.il", page: .page)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian])
    }

    func testLeavingTheSiteForANonWebPageAppliesTheBrowserRule() {
        make([.app(zen, IDs.russian), site("ynet.co.il", IDs.hebrew)])
        show()
        show(host: nil, domain: nil, page: .notWebPage)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian])
    }

    func testAPrivateFlagChangeIsNotPageStateOnly() {
        make([.app(zen, IDs.russian), site("ynet.co.il", IDs.hebrew)])
        store.update { $0.browsers.ignorePrivateWindowsCompletely = true }
        sut.preferencesDidChange()
        show(private: false)
        show(private: true)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian])
    }

    func testAnotherPidWithTheSameSiteIsNotPageStateOnly() {
        make([site("ynet.co.il", IDs.hebrew)])
        show(page: .page, pid: 7)
        switcher.current = IDs.abc
        show(page: .unknown, pid: 8)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.hebrew])
    }

    func testDifferenceIgnoresTheGeneration() {
        let none = RuleEngine(rules: [])
        let override = RuleEngine(rules: [host("c.b", IDs.hebrew)])
        let a = Context(bundleID: zen, pid: 1, host: "a.b", siteDomain: "b", pageState: .page, generation: 1)
        var b = a
        b.pageState = .unknown
        XCTAssertTrue(SwitchController.differsOnlyInPageState(a, b, engine: none))
        XCTAssertFalse(SwitchController.differsOnlyInPageState(a, a, engine: none), "no change at all is not a page-state change")
        var c = b
        c.host = "c.b"
        XCTAssertFalse(SwitchController.differsOnlyInPageState(a, c, engine: override))
        let fromNoBrowser = Context(bundleID: zen, pid: 1, host: "a.b", siteDomain: "b", pageState: nil, generation: 2)
        XCTAssertTrue(SwitchController.differsOnlyInPageState(fromNoBrowser, a, engine: none))
    }

    /// QA (P3-9): ContextAssembler drops a host change inside one site (no override), so the next page-state
    /// change carries the newer host. That is still page-state-only for the rules: the manual switch stays.
    func testAStaleHostWithoutAnOverrideIsStillPageStateOnly() {
        make([site("google.com", IDs.hebrew)])
        show(host: "www.google.com", domain: "google.com")
        userSwitch(to: IDs.abc)                                   // on mail.google.com by now (not emitted)
        show(host: "mail.google.com", domain: "google.com", page: .editingAddress)
        show(host: "mail.google.com", domain: "google.com", page: .page)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew], "the manual switch is not undone")
        XCTAssertEqual(switcher.current, IDs.abc)
    }

    func testAHostChangeOntoAnOverrideReappliesWithThePageState() {
        make([site("google.com", IDs.hebrew), host("mail.google.com", IDs.russian)])
        show(host: "www.google.com", domain: "google.com")
        show(host: "mail.google.com", domain: "google.com", page: .editingAddress)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian])
        show(host: "www.google.com", domain: "google.com", page: .page)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.russian, IDs.hebrew], "leaving the override re-applies")
    }

    func testHostCaseAndTrailingDotDontCount() {
        make([site("ynet.co.il", IDs.hebrew), host("www.ynet.co.il", IDs.hebrew)])
        show(host: "www.ynet.co.il")
        userSwitch(to: IDs.abc)
        show(host: "WWW.ynet.co.il.", page: .editingAddress)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    /// The learner sequence: a switch made in the address bar can't be learned for the site once the page is back.
    func testASwitchInTheAddressBarIsNotLearnedAfterReturningToThePage() {
        make()
        show()
        show(page: .editingAddress)
        userSwitch(to: IDs.hebrew)
        XCTAssertNil(sut.learner.pending)
        show(page: .page)
        twoWords()
        clock.advance(byMilliseconds: 5_000)
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testACandidateIsDroppedWhenThePageBecomesUnreadable() {
        make()
        show()
        userSwitch(to: IDs.hebrew)
        XCTAssertNotNil(sut.learner.pending)
        show(page: .unknown)
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    // MARK: - Learning on a site vs the app

    func testManualSwitchOnASiteLearnsTheSiteInPunycode() {
        make([.app(zen, IDs.abc, .pinned)])
        show(host: "www.שלום.co.il", domain: "שלום.co.il")
        userSwitch(to: IDs.hebrew)
        twoWords()
        let learned = store.prefs.rules.first { $0.scope.kind == .site }
        XCTAssertEqual(learned?.scope, .site(domain: "xn--9dbne9b.co.il"))
        XCTAssertEqual(learned?.inputSource, IDs.hebrew)
        XCTAssertEqual(store.prefs.rules.first { $0.scope.kind == .app }?.inputSource, IDs.abc, "the pin is untouched")
    }

    func testManualSwitchOnANonWebPageLearnsTheBrowser() {
        make()
        show(host: nil, domain: nil, page: .notWebPage)
        userSwitch(to: IDs.hebrew)
        twoWords()
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: zen)])
    }

    func testNothingIsLearnedOnAnUnknownPageOrInTheAddressBar() {
        make()
        show(page: .unknown)
        userSwitch(to: IDs.hebrew)
        twoWords()
        show(page: .editingAddress)
        userSwitch(to: IDs.abc)
        twoWords()
        show(host: nil, domain: nil, page: .unknown)
        userSwitch(to: IDs.hebrew)
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testNothingIsLearnedInAPrivateWindow() {
        make()
        show(private: true)
        userSwitch(to: IDs.hebrew)
        twoWords()
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testDebugLearnerLineSaysSiteWithoutTheDomain() {
        make()
        show()
        userSwitch(to: IDs.hebrew)
        XCTAssertTrue(sut.learnerDebug.contains("candidate site→com.apple.keylayout.Hebrew"), sut.learnerDebug)
        twoWords()
        XCTAssertTrue(sut.learnerDebug.contains("learned site→"), sut.learnerDebug)
        XCTAssertFalse(sut.learnerDebug.contains("ynet"), sut.learnerDebug)

        show(page: .editingAddress)
        userSwitch(to: IDs.abc)
        XCTAssertTrue(sut.learnerDebug.contains("editingAddress"), sut.learnerDebug)
        XCTAssertFalse(sut.learnerDebug.contains("ynet"), sut.learnerDebug)
    }

    // MARK: - Pin

    func testPinOnASiteWritesThePunycodeSite() {
        make([.app(zen, IDs.abc, .pinned)])
        show(host: "www.שלום.co.il", domain: "שלום.co.il")
        switcher.current = IDs.hebrew
        let pinned = sut.pinCurrent()
        XCTAssertEqual(pinned?.scope, .site(domain: "xn--9dbne9b.co.il"))
        XCTAssertEqual(pinned?.origin, .pinned)
        XCTAssertEqual(store.prefs.rules.count, 2, "the browser pin stays")
    }

    func testPinInAPrivateWindowPinsTheSite() {
        make()
        show(private: true)
        switcher.current = IDs.hebrew
        XCTAssertEqual(sut.currentRule?.pinScope, .site(domain: "ynet.co.il"))
        XCTAssertEqual(sut.pinCurrent()?.scope, .site(domain: "ynet.co.il"))
    }

    func testPinOnAHostOverrideUpdatesTheOverride() {
        make([host("news.ynet.co.il", IDs.abc)])
        show(host: "news.ynet.co.il")
        switcher.current = IDs.hebrew
        XCTAssertEqual(sut.pinCurrent()?.scope, .siteHost(host: "news.ynet.co.il"))
        XCTAssertEqual(store.prefs.rules.count, 1)
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew)
    }

    func testPinWithoutASitePinsTheBrowser() {
        make()
        show(host: nil, domain: nil, page: .notWebPage)
        XCTAssertEqual(sut.pinCurrent()?.scope, .app(bundleID: zen))
        show(host: nil, domain: nil, page: .unknown)
        XCTAssertEqual(sut.currentRule?.pinScope, .app(bundleID: zen))
    }

    // MARK: - Forget (D6)

    func testForgetOnASiteRemovesTheSiteRuleOnly() {
        make([.app(zen, IDs.russian, .pinned), site("ynet.co.il", IDs.hebrew)])
        show()
        XCTAssertEqual(sut.currentRule?.forgetScope, .site(domain: "ynet.co.il"))
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: zen)])
        XCTAssertNil(sut.currentRule?.forgetScope, "now the browser's rule matches: Forget is off on the site")
        XCTAssertFalse(sut.forgetCurrent())
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.app(bundleID: zen)], "the browser pin is never forgotten here")
    }

    func testForgetOnAHostOverride() {
        make([site("ynet.co.il", IDs.hebrew), host("news.ynet.co.il", IDs.abc)])
        show(host: "news.ynet.co.il")
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertEqual(store.prefs.rules.map(\.scope), [.site(domain: "ynet.co.il")])
    }

    func testForgetOnANonWebPageRemovesTheBrowserRule() {
        make([.app(zen, IDs.russian, .pinned)])
        show(host: nil, domain: nil, page: .notWebPage)
        XCTAssertEqual(sut.currentRule?.forgetScope, .app(bundleID: zen))
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testForgetAnOldUnicodeRuleOnASite() {
        make([site("שלום.co.il", IDs.hebrew)])
        show(host: "www.xn--9dbne9b.co.il", domain: "xn--9dbne9b.co.il")
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testForgetInAnAppThatIsNoBrowserIsUnchanged() {
        make([.app("com.apple.Notes", IDs.hebrew)])
        monitor.onChange = { [unowned self] c in self.sut.contextDidChange(c) }
        monitor.activate("com.apple.Notes", pid: 3)
        XCTAssertTrue(sut.forgetCurrent())
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }
}
