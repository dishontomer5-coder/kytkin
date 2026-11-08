// P3-31 (owner decision 2026-11-08): the Find box (⌘F) and other toolbar fields (`.editingBrowserField`) keep the
// site's language; only the real address bar (`.editingAddress`) gets the browser's language (P3-29). Nothing is
// learned in either. The switch off → the old D5 behaviour for both. Races: a `.unknown` read in the Find box keeps
// the site's language; a quick bar → Find box → bar sequence applies each time.

import XCTest

@MainActor
final class FindBoxSwitchTests: XCTestCase {
    private var clock: FakeClock!
    private var switcher: FakeSwitcher!
    private var monitor: FakeContextMonitor!
    private var store: PreferencesStore!
    private var sut: SwitchController!
    private let zen = "app.zen-browser.zen"
    private let date = Date(timeIntervalSince1970: 5_000)
    private var generation: UInt64 = 100

    private func make(_ rules: [Rule] = [], on: Bool = true, current: InputSourceID = IDs.hebrew) {
        var p = Preferences()
        p.rules = rules
        p.browsers.browserLanguageInAddressBar = on
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
                      domain: String? = "ynet.co.il", private isPrivate: Bool? = nil) -> SwitchController.ContextChange {
        generation += 1
        let c = Context(bundleID: zen, pid: 7, host: host, siteDomain: domain, isPrivateWindow: isPrivate,
                        pageState: page, generation: generation)
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

    // MARK: - The Find box keeps the site's language

    func testFromThePageIntoTheFindBoxNothingChanges() {
        make([site("ynet.co.il", IDs.hebrew)], current: IDs.abc)
        show()
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
        XCTAssertEqual(show(.editingBrowserField), .pageStateOnly(from: .page, to: .editingBrowserField))
        XCTAssertEqual(switcher.current, IDs.hebrew, "the site's language in the Find box")
        XCTAssertEqual(sut.currentRule?.resolution.level, .site, "the menu names the site, not the address bar")
        XCTAssertEqual(show(.page), .pageStateOnly(from: .editingBrowserField, to: .page))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    func testAManualSwitchOnThePageSurvivesTheFindBox() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        userSwitch(to: IDs.russian)
        show(.editingBrowserField)
        XCTAssertEqual(switcher.current, IDs.russian, "D5: a page-state-only change doesn't undo a manual switch")
    }

    func testFromTheBarIntoTheFindBoxTheSitesLanguageComesBack() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        XCTAssertEqual(show(.editingAddress), .full)
        XCTAssertEqual(switcher.current, IDs.abc, "the bar: English")
        XCTAssertEqual(show(.editingBrowserField), .full, "bar → Find box: the rule changes")
        XCTAssertEqual(switcher.current, IDs.hebrew)
        XCTAssertEqual(show(.editingAddress), .full)
        XCTAssertEqual(switcher.current, IDs.abc)
        XCTAssertEqual(switcher.selectedIDs, [IDs.abc, IDs.hebrew, IDs.abc], "already Hebrew on the page")
    }

    func testTheBrowsersAppRuleDoesNotApplyInTheFindBoxOnASiteWithARule() {
        make([Rule(scope: .app(bundleID: zen), inputSource: IDs.russian, origin: .pinned, updatedAt: date),
              site("ynet.co.il", IDs.hebrew)])
        show(.editingBrowserField)
        XCTAssertEqual(switcher.current, IDs.hebrew, "site beats the browser pin, as on the page")
    }

    func testTheSwitchOffTreatsBothFieldsLikeThePage() {
        make([site("ynet.co.il", IDs.hebrew)], on: false, current: IDs.abc)
        show()
        XCTAssertEqual(show(.editingAddress), .pageStateOnly(from: .page, to: .editingAddress))
        XCTAssertEqual(show(.editingBrowserField), .pageStateOnly(from: .editingAddress, to: .editingBrowserField))
        XCTAssertEqual(switcher.selectedIDs, [IDs.hebrew])
    }

    // MARK: - Races

    func testAnUnknownReadInTheFindBoxKeepsTheSitesLanguage() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingBrowserField)
        XCTAssertEqual(show(.unknown), .pageStateOnly(from: .editingBrowserField, to: .unknown))
        XCTAssertEqual(switcher.current, IDs.hebrew, "not taken for the bar")
        XCTAssertEqual(sut.currentRule?.resolution.level, .site)
        XCTAssertEqual(show(.editingBrowserField), .pageStateOnly(from: .unknown, to: .editingBrowserField))
        XCTAssertEqual(switcher.selectedIDs, [])
    }

    func testAnUnknownReadInTheBarStillKeepsTheBarsLanguage() {
        // The P3-29 QA fix holds next to the Find box: bar → unknown → bar never flips.
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        show(.unknown)
        XCTAssertEqual(switcher.current, IDs.abc)
        XCTAssertEqual(show(.editingBrowserField), .full, "then the Find box: the site's language")
        XCTAssertEqual(switcher.current, IDs.hebrew)
        XCTAssertEqual(switcher.selectedIDs, [IDs.abc, IDs.hebrew])
    }

    func testABarSwitchStillUnconfirmedWhenTheFindBoxContextArrives() {
        // ⌘L then ⌘F at once: the bar's select went out, its notification comes back after the Find box applied.
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingAddress)
        clock.advance(byMilliseconds: 20)
        show(.editingBrowserField)
        sut.inputSourceDidChange(.ours(IDs.abc))
        sut.inputSourceDidChange(.ours(IDs.hebrew))
        XCTAssertEqual(switcher.current, IDs.hebrew)
        XCTAssertEqual(switcher.selectedIDs, [IDs.abc, IDs.hebrew], "no re-assert")
        for _ in 0..<3 { sut.wordBoundary() }
        XCTAssertEqual(store.prefs.rules.count, 1)
    }

    // MARK: - Never learn from the Find box

    func testTypingInTheFindBoxLearnsNothing() {
        make([site("ynet.co.il", IDs.hebrew)])
        show()
        show(.editingBrowserField)
        userSwitch(to: IDs.russian)
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertEqual(store.prefs.rules.count, 1)
        XCTAssertEqual(store.prefs.rules.first?.inputSource, IDs.hebrew, "the site rule is unchanged")
        XCTAssertNil(sut.learner.pending)
    }

    func testTheFindBoxOnAPageWithoutASiteRuleDoesNotTeachTheSiteOrTheApp() {
        make()
        show(.editingBrowserField)
        userSwitch(to: IDs.russian)
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testAPageCandidateIsDroppedWhenFocusMovesToTheFindBox() {
        make()
        show()
        userSwitch(to: IDs.russian)
        XCTAssertNotNil(sut.learner.pending)
        show(.editingBrowserField)
        XCTAssertNil(sut.learner.pending)
        for _ in 0..<5 { sut.wordBoundary() }
        XCTAssertTrue(store.prefs.rules.isEmpty)
    }

    func testTheLearnerDiscardsTheFindBox() {
        let e = RuleEngine(rules: [], addressBarUsesBrowserLanguage: true, addressBarSource: IDs.abc)
        var l = RuleLearner(engine: e, keyboardTapAvailable: true, currentSource: IDs.abc)
        let c = Context(bundleID: zen, pid: 7, host: "www.ynet.co.il", siteDomain: "ynet.co.il",
                        pageState: .editingBrowserField, generation: 1)
        _ = l.handle(.contextChanged(c, atNanos: 10_000_000_000))
        XCTAssertEqual(l.handle(.externalSwitch(IDs.hebrew, atNanos: 11_000_000_000)), .discard(.editingAddress))
        XCTAssertNil(l.pending)
    }

    // MARK: - RuleEngine, word buffer

    func testTheEngineResolvesTheFindBoxLikeThePage() {
        let e = RuleEngine(rules: [site("ynet.co.il", IDs.hebrew)], addressBarUsesBrowserLanguage: true,
                           addressBarSource: IDs.abc)
        let c = Context(bundleID: zen, pid: 7, host: "www.ynet.co.il", siteDomain: "ynet.co.il",
                        pageState: .editingBrowserField, generation: 1)
        XCTAssertFalse(e.usesBrowserLanguage(c))
        XCTAssertEqual(e.resolve(c).target, IDs.hebrew)
        XCTAssertEqual(e.resolve(c).level, .site)
        var noSite = c
        noSite.host = nil
        noSite.siteDomain = nil
        XCTAssertEqual(e.resolve(noSite).level, .none, "no site, no app rule: keep current (not the bar's English)")
    }

    func testTheFindBoxIsAnotherFieldForTheWordBuffer() {
        XCTAssertFalse(AppController.keepsWordBuffer(.pageStateOnly(from: .page, to: .editingBrowserField)))
        XCTAssertFalse(AppController.keepsWordBuffer(.pageStateOnly(from: .editingBrowserField, to: .page)))
    }
}
