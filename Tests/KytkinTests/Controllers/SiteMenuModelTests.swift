// P3-9: the menu's site form (001 §14.9), row by row (P6-0g: "On <site>" and the Kytkin key): Pin ("on" the site) and Forget (D6), the
// private-window marker, Unicode display of Punycode hosts (D13), and the app form for non-web pages.

import XCTest

@MainActor
final class SiteMenuModelTests: XCTestCase {
    private let zen = "app.zen-browser.zen"
    private let names = ["app.zen-browser.zen": "Zen", "com.apple.Notes": "Notes"]
    private let sourceNames = [IDs.abc: "English", IDs.hebrew: "Hebrew"]
    private let date = Date(timeIntervalSince1970: 5_000)

    private func source(_ id: InputSourceID) -> InputSourceInfo {
        InputSourceInfo(id: id, name: sourceNames[id] ?? id.rawValue, languageCode: id == IDs.hebrew ? "he" : "en",
                        isEnabled: true, isConvertible: true, isInputMethod: false)
    }

    private func site(_ domain: String, _ id: InputSourceID, _ origin: RuleOrigin = .learned) -> Rule {
        Rule(scope: .site(domain: domain), inputSource: id, origin: origin, updatedAt: date)
    }

    private func host(_ host: String, _ id: InputSourceID, _ origin: RuleOrigin = .pinned) -> Rule {
        Rule(scope: .siteHost(host: host), inputSource: id, origin: origin, updatedAt: date)
    }

    /// The three context lines for `c` under `rules`, as SwitchController would describe it.
    private func lines(_ rules: [Rule], host: String? = "www.ynet.co.il", domain: String? = "ynet.co.il",
                       private isPrivate: Bool? = nil, page: BrowserPageState? = .page,
                       defaultBehavior: DefaultBehavior = .keepCurrent,
                       current: InputSourceID? = IDs.hebrew) -> [MenuItemModel] {
        let c = Context(bundleID: zen, pid: 7, host: host, siteDomain: domain, isPrivateWindow: isPrivate,
                        pageState: page, generation: 1)
        let engine = RuleEngine(rules: rules, defaultBehavior: defaultBehavior)
        var state = MenuState()
        state.pairInputSources = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        state.currentRule = SwitchController.CurrentRule(context: c, resolution: engine.resolve(c),
                                                         pinScope: engine.pinScope(for: c))
        return MenuModel.contextItems(state: state, currentSource: current.map(source),
                                      sourceName: { self.sourceNames[$0] ?? $0.rawValue }, sourceCode: { $0 == IDs.abc ? "EN" : "HE" },
                                      appName: { self.names[$0] ?? $0 })
    }

    // MARK: - §14.9 rows (P6-0g: "On <site>", the Kytkin key, Follow My Last Switch; Turn Off Double-Shift, Forget Rule)

    private func key(_ chosen: PairSide?) -> MenuItemModel {
        .languageKey("Always use", MenuItemModel.LanguageKey(
            a: .init(letters: "EN", name: "English", source: IDs.abc),
            b: .init(letters: "HE", name: "Hebrew", source: IDs.hebrew), chosen: chosen))
    }

    private func follow(_ checked: Bool) -> MenuItemModel {
        .action("Follow My Last Switch", .unpinCurrent, checked: checked)
    }

    private func dont(_ checked: Bool = false) -> MenuItemModel {
        .action("Turn Off Double-Shift in Zen", .toggleConvertInCurrentApp, checked: checked)
    }

    private func forget(_ name: String) -> MenuItemModel { .action("Forget Rule for \(name)", .forgetCurrent) }

    func testSiteRule() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)]), [
            .header("On ynet.co.il"), key(nil), follow(true), .separator, dont(), forget("ynet.co.il"),
        ])
    }

    func testPinnedSiteRuleFillsItsHalf() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew, .pinned)]), [
            .header("On ynet.co.il"), key(.b), follow(false), .separator, dont(), forget("ynet.co.il"),
        ])
        let other = lines([site("ynet.co.il", IDs.hebrew, .pinned)], current: IDs.abc)
        XCTAssertEqual(other[1], key(.b), "the key shows the pin, whatever is selected now")
    }

    func testHostOverride() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew), host("news.ynet.co.il", IDs.abc)],
                             host: "news.ynet.co.il", current: IDs.abc), [
            .header("On news.ynet.co.il"), key(.a), follow(false), .separator, dont(), forget("news.ynet.co.il"),
        ])
    }

    func testBrowserRuleApplies() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], current: IDs.abc), [
            .header("On ynet.co.il"), key(nil), follow(true), .separator, dont(),
        ], "the browser's rule is no rule of the site's: nothing filled, nothing to forget here")
        XCTAssertEqual(lines([.app(zen, IDs.abc)])[0], .header("On ynet.co.il"), "learned browser rule too")
    }

    func testDefault() {
        XCTAssertEqual(lines([], defaultBehavior: .switchTo(IDs.abc), current: IDs.abc)[0], .header("On ynet.co.il"))
    }

    func testNoRule() {
        XCTAssertEqual(lines([]), [.header("On ynet.co.il"), key(nil), follow(true), .separator, dont()])
    }

    func testPrivateWindow() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], private: true)[0], .header("On ynet.co.il (private)"))
        XCTAssertEqual(lines([], private: nil)[0], .header("On ynet.co.il"), "unknown is not private")
        XCTAssertEqual(lines([], private: false)[0], .header("On ynet.co.il"))
    }

    func testNotAWebPageUsesTheAppForm() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], host: nil, domain: nil, page: .notWebPage,
                             current: IDs.abc), [
            .header("In Zen"), key(.a), follow(false), .separator, dont(), forget("Zen"),
        ])
    }

    func testUnknownWithNoSiteUsesTheAppForm() {
        XCTAssertEqual(lines([], host: nil, domain: nil, page: .unknown),
                       [.header("In Zen"), key(nil), follow(true), .separator, dont()])
    }

    func testUnknownOrEditingWithAKeptSiteUsesTheSiteForm() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .unknown)[0], .header("On ynet.co.il"))
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .editingAddress)[5], forget("ynet.co.il"))
    }

    func testNoPageStateMeansNoSiteForm() {
        // pageState nil = not a watched browser: the app form.
        XCTAssertEqual(lines([], private: true, page: nil)[0], .header("In ynet.co.il"), "no (private) marker")
    }

    // MARK: - Unicode display (D13)

    func testPunycodeHostsAreShownInUnicode() {
        let idn = "xn--9dbne9b.co.il"
        XCTAssertEqual(lines([site(idn, IDs.hebrew)], host: "www." + idn, domain: idn), [
            .header("On שלום.co.il"), key(nil), follow(true), .separator, dont(), forget("שלום.co.il"),
        ])
    }

    func testAnOldUnicodeRuleIsStillCheckedAsThePin() {
        let idn = "xn--9dbne9b.co.il"
        let out = lines([site("שלום.co.il", IDs.hebrew, .pinned)], host: "www." + idn, domain: idn)
        XCTAssertEqual(out[1], key(.b))
    }

    func testScopeNameShowsUnicode() {
        let app: (String) -> String = { _ in "X" }
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "xn--9dbne9b.co.il"), appName: app), "שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.siteHost(host: "www.xn--9dbne9b.co.il"), appName: app), "www.שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "Ynet.co.il."), appName: app), "ynet.co.il")
    }

    func testNoCurrentSourceStillOffersTheKeyOnASite() {
        XCTAssertEqual(lines([], current: nil)[1], key(nil))
    }
}
