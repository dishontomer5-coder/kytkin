// P3-29 (plan.md decision 2026-11-08, owner): SwitchController and ContextAssembler with "Use the browser's language
// in the address bar". Into the bar → the browser's app rule, else English (the pair's Latin member); back to the
// page → the site's language again. Nothing is learned from the bar (neither the site nor the browser's app rule).
// The switch off → the old D5 behaviour. Pause, Kytkin off and Kytkin's own window: unchanged. Races: a page rule's
// switch still unconfirmed (its change notification not yet in) when the bar's Context arrives, and a page
// observation still held by the assembler's debounce when the bar's observation comes.

import XCTest

@MainActor
final class AddressBarSwitchTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var store: PreferencesStore!
    private var sut: SwitchController!
    private let zen = "app.zen-browser.zen"
    private let date = Date(timeIntervalSince1970: 5_000)
    private var generation: UInt64 = 100

    private func make(_ rules: [Rule] = [], on: Bool = true, current: InputSourceID = IDs.hebrew,
                      pair: LanguagePair = .default) {
        var p = Preferences()
        p.rules = rules
        p.browsers.browserLanguageInAddressBar = on
        p.languagePair = pair
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: current)
        monitor = FakeContextMonitor()
        store = makeStore(p, clock: clock)
        sut = SwitchController(switcher: switcher, context: monitor, store: store, conflicts: FakeConflicts(),
                               clock: clock, now: { [date] in date })
        sut.setKeyboardTapAvailable(true)
    }

    @discardableResult
    private func show(_ page: BrowserPageState? = .page, host: String? = "www.ynet.co.il",
                      domain: String? = "ynet.co.il", private isPrivate: Bool? = nil, bundleID: String? = nil,
                      pid: Int32 = 7) -> SwitchController.ContextChange {
        generation += 1
        let c = Context(bundleID: bundleID ?? zen, pid: pid, host: host, siteDomain: domain,
                        isPrivateWindow: isPrivate, pageState: page, generation: generation)
        monitor.current = c
        return sut.contextDidChange(c)
    }

    private func site(_ domain: String, _ source: InputSourceID) -> Rule {
        Rule(scope: .site(domain: domain), inputSource: source, origin: .learned, updatedAt: date)
    }

    private func userSwitch(to id: InputSourceID) {
        clock.advance(byMilliseconds: 600)
        switcher.current = id
        sut.inputSourceDidChange(.external(id, atNanos: clock.nowNanos))
    }

    // MARK: - Into the bar and back

    func testIntoTheBarIsEnglishAndBackToThePageIsTheSitesLanguage() {
        make([site("ynet.co.il", IDs.hebrew)], current: IDs.abc)
        show()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        XCTAssertEqual(show(.editingAddress), .full, "a full change: the word buffer is reset too")
        XCTAssertEqual(switcher.current, IDs.abc, "no app rule: English")
        show(.page)
        XCTAssertEqual(switcher.current, IDs.hebrew, "back to the site's language")
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.abc, IDs.hebrew])
        XCTAssertTrue(switcher.selects.allSatisfy { $0.1 == .rule })
    }

    func testTheBrowsersAppRuleWinsInTheBar() {
        make([.app(zen, IDs.russian), site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.russian)
        show(.page)
        XCTAssertEqual(switcher.current, IDs.hebrew)
    }

    func testLeavingTheBarForAnUnknownReadStillUsesTheKeptSite() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        show(.unknown)   // e.g. focus to Zen's sidebar
        XCTAssertEqual(switcher.current, IDs.hebrew)
    }

    func testANewTabsOmniboxIsEnglish() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress, host: nil, domain: nil)   // ⌘T: new tab, focus in the omnibox
        XCTAssertEqual(switcher.current, IDs.abc)
    }

    func testANonLatinPairKeepsTheLanguageInTheBar() {
        let pair = LanguagePair(a: IDs.hebrew, b: IDs.russian)   // no Latin member: the default (keep current)
        make([site("ynet.co.il", IDs.russian)], pair: pair)
        show()
        XCTAssertEqual(switcher.current, IDs.russian)
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.russian)
        XCTAssertEqual(switcher.selectedIDs, [IDs.russian])
    }

    func testTheResolverIsAskedForThePair() {
        var asked: [LanguagePair] = []
        var p = Preferences()
        p.languagePair = LanguagePair(a: IDs.russian, b: IDs.hebrew)
        clock = FakeClock(nowNanos: 1_000_000_000)
        switcher = FakeSwitcher(current: IDs.hebrew)
        monitor = FakeContextMonitor()
        store = makeStore(p, clock: clock)
        sut = SwitchController(switcher: switcher, context: monitor, store: store, conflicts: FakeConflicts(),
                               clock: clock, addressBarLanguage: { pair in asked.append(pair); return IDs.russian })
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.russian)
        XCTAssertEqual(asked.last, p.languagePair)
    }

    // MARK: - The switch

    func testSwitchOffKeepsTheSiteLanguageInTheBar() {
        make([site("ynet.co.il", IDs.hebrew)], on: false, current: IDs.abc)
        show()
        XCTAssertEqual(show(.editingAddress), .pageStateOnly(from: .page, to: .editingAddress))
        XCTAssertEqual(switcher.current, IDs.hebrew)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testTurningTheSwitchOffAndOnTakesEffectOnTheNextMove() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        store.update { $0.browsers.browserLanguageInAddressBar = false }
        sut.preferencesDidChange()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.hebrew)
        show(.page)
        store.update { $0.browsers.browserLanguageInAddressBar = true }
        sut.preferencesDidChange()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.abc)
    }

    // MARK: - Never learn from the bar

    func testTypingInTheBarLearnsNothing() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        userSwitch(to: IDs.russian)            // the user picks another language in the bar
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertEqual(store.prefs.rules.count, 1, "no app rule for the browser")
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew, "the site rule is unchanged")
        XCTAssertNil(sut.learner.pending)
    }

    func testTypingInANewTabsOmniboxDoesNotTeachTheBrowsersAppRule() {
        make()
        show(.editingAddress, host: nil, domain: nil)
        userSwitch(to: IDs.hebrew)
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testAPageCandidateIsDroppedWhenFocusMovesToTheBar() {
        make()
        show()
        userSwitch(to: IDs.russian)
        XCTAssertNotNil(sut.learner.pending)
        show(.editingAddress)
        XCTAssertNil(sut.learner.pending)
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertTrue(store.prefs.rules.isEmpty, "words typed in the bar don't confirm the page's candidate")
    }

    // MARK: - Private windows

    func testAPrivateWindowsBarIsEnglishToo() {
        make([site("ynet.co.il", IDs.hebrew)])
        show(private: true)
        XCTAssertEqual(switcher.current, IDs.hebrew)
        show(.editingAddress, private: true)
        XCTAssertEqual(switcher.current, IDs.abc)
        userSwitch(to: IDs.russian)
        for _ in 0..<3 { sut.wordBoundary() }
        XCTAssertEqual(store.prefs.rules.count, 1)
    }

    func testAnIgnoredPrivateWindowsBarWithoutASite() {
        // The reader reports (nil site, .editingAddress, private) there (AddressBarFocusTests).
        make([.app(zen, IDs.russian), site("ynet.co.il", IDs.hebrew)])
        store.update { $0.browsers.ignorePrivateWindowsCompletely = true }
        sut.preferencesDidChange()
        show(.unknown, host: nil, domain: nil, private: true)
        XCTAssertEqual(switcher.current, IDs.russian)
        show(.editingAddress, host: nil, domain: nil, private: true)
        XCTAssertEqual(switcher.current, IDs.russian)
    }

    // MARK: - Pause, off, Kytkin's own window, a disabled app

    func testPauseAndOffAndADisabledBrowserStillSwitchNothing() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        sut.setPaused(true)
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.hebrew)
        show(.page)
        sut.setPaused(false)
        XCTAssertEqual(switcher.selectedIDs, [], "already Hebrew")

        store.update { $0.general.enabled = false }
        sut.preferencesDidChange()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.hebrew)
        store.update { $0.general.enabled = true }
        sut.preferencesDidChange()
        XCTAssertEqual(switcher.current, IDs.abc, "turning Kytkin back on re-applies: the bar still has focus")

        show(.page)
        store.update { $0.apps[zen] = Preferences.AppOverride(disabled: true) }
        sut.preferencesDidChange()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.hebrew)
    }

    func testKytkinsOwnWindowThenBackToTheBar() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        XCTAssertEqual(switcher.current, IDs.abc)
        sut.kytkinDidBecomeActive()
        switcher.current = IDs.russian                 // e.g. the user switched while Settings was in front
        sut.kytkinDidResignActive(frontmostPID: 7)
        XCTAssertEqual(switcher.current, IDs.abc, "back in the browser, still in the bar: the bar's language")
    }

    // MARK: - Races

    func testThePageSwitchIsStillUnconfirmedWhenTheBarsContextArrives() {
        // ⌘L right after a tab switch: the page rule's select went out, but its change notification hasn't come
        // back yet when the bar's Context arrives. The bar wins, both notifications are ours, nothing is learned,
        // and neither is taken as a fight.
        make([site("ynet.co.il", IDs.hebrew)], current: IDs.russian)
        show(host: "www.haaretz.co.il", domain: "haaretz.co.il")   // no rule: keep current
        show()                                                      // the ynet tab: select Hebrew…
        clock.advance(byMilliseconds: 20)
        show(.editingAddress)                                       // …and ⌘L before its notification
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.abc])
        clock.advance(byMilliseconds: 10)
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        sut.inputSourceDidChange(.ours(IDs.abc))
        XCTAssertEqual(switcher.current, IDs.abc)
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew, IDs.abc], "no re-assert")
        for _ in 0..<3 { sut.wordBoundary() }
        XCTAssertEqual(store.prefs.rules.count, 1)
    }

    func testAPageObservationHeldByTheDebounceIsReplacedByTheBar() {
        // The assembler holds a page read (a burst) when the bar's read comes: one Context, the bar's.
        let clock = FakeClock(nowNanos: 5_000_000_000)
        var a = ContextAssembler(clock: clock, ownPID: 1, ownBundleID: "io.github.kytkin.Kytkin")
        let ynet = SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true)
        let haaretz = SiteAddress(host: "www.haaretz.co.il", registrableDomain: "haaretz.co.il", isWebPage: true)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 7, awaitsSite: true))
        XCTAssertNotNil(a.browserObserved(site: haaretz, pageState: .page, isPrivate: nil, pid: 7))
        clock.advance(byMilliseconds: 500)
        XCTAssertNotNil(a.browserObserved(site: haaretz, pageState: .editingAddress, isPrivate: nil, pid: 7))
        clock.advance(byMilliseconds: 30)
        XCTAssertNil(a.browserObserved(site: ynet, pageState: .page, isPrivate: nil, pid: 7), "held: a burst")
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.browserObserved(site: ynet, pageState: .editingAddress, isPrivate: nil, pid: 7))
        clock.advance(byMilliseconds: 200)
        let emitted = a.flushIfDue()
        XCTAssertEqual(emitted?.pageState, .editingAddress)
        XCTAssertEqual(emitted?.siteDomain, "ynet.co.il")
        XCTAssertNil(a.flushIfDue(), "one Context for the burst")
    }

    func testABrowserActivatedWithTheBarFocusedSwitchesOnceToTheBarsLanguage() {
        // A new window (⌘N) opens with focus in the bar: the site grace's first read is the bar's.
        let clock = FakeClock(nowNanos: 5_000_000_000)
        var a = ContextAssembler(clock: clock, ownPID: 1, ownBundleID: "io.github.kytkin.Kytkin")
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 7, awaitsSite: true), "held for the first read")
        clock.advance(byMilliseconds: 15)
        let c = a.browserObserved(site: nil, pageState: .editingAddress, isPrivate: nil, pid: 7)
        XCTAssertEqual(c?.pageState, .editingAddress)
        make([site("ynet.co.il", IDs.hebrew)])
        monitor.current = c
        sut.contextDidChange(try! XCTUnwrap(c))
        XCTAssertEqual(switcher.selectedIDs, [IDs.abc])
    }

    // MARK: - Menu

    func testTheMenuLineSaysAddressBar() {
        make([site("ynet.co.il", IDs.hebrew)])
        show(.editingAddress)
        let rule = try! XCTUnwrap(sut.currentRule)
        XCTAssertEqual(rule.resolution.level, .addressBar)
        XCTAssertNil(rule.forgetScope, "the browser's language isn't a rule to forget")
        let items = MenuModel.contextItems(state: MenuState(currentRule: rule), currentSource: nil,
                                           sourceName: { $0 == IDs.abc ? "ABC" : $0.rawValue }, appName: { _ in "Zen" })
        XCTAssertEqual(items.first, .info("ynet.co.il (Zen): ABC (address bar)"))
    }
}
