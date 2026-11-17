// P3-9: the menu's site form (001 §14.9), row by row: context line, Pin ("on" the site) and Forget (D6), the
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
        state.currentRule = SwitchController.CurrentRule(context: c, resolution: engine.resolve(c),
                                                         pinScope: engine.pinScope(for: c))
        return MenuModel.contextItems(state: state, currentSource: current.map(source),
                                      sourceName: { self.sourceNames[$0] ?? $0.rawValue },
                                      appName: { self.names[$0] ?? $0 })
    }

    // MARK: - §14.9 rows (P6-0c: header, plain "why" line, Always Use, Forget, Don't Convert)

    private func dont(_ checked: Bool = false) -> MenuItemModel {
        .action("Don't Convert in Zen", .toggleConvertInCurrentApp, checked: checked)
    }

    func testSiteRule() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)]), [
            .header("ynet.co.il · Hebrew"),
            .info("Remembered from your switches"),
            .action("Always Use Hebrew on ynet.co.il", .pinCurrent),
            .action("Forget Rule for ynet.co.il", .forgetCurrent),
            dont(),
        ])
    }

    func testPinnedSiteRuleIsCheckedAndChoosingItAgainUnpins() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew, .pinned)]), [
            .header("ynet.co.il · Hebrew"),
            .info("Always Hebrew (you chose this)"),
            .action("Always Use Hebrew on ynet.co.il", .unpinCurrent, checked: true),
            .action("Forget Rule for ynet.co.il", .forgetCurrent),
            dont(),
        ])
        let other = lines([site("ynet.co.il", IDs.hebrew, .pinned)], current: IDs.abc)
        XCTAssertEqual(other[2], .action("Always Use English on ynet.co.il", .pinCurrent), "another language: not done")
    }

    func testHostOverride() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew), host("news.ynet.co.il", IDs.abc)],
                             host: "news.ynet.co.il", current: IDs.abc), [
            .header("news.ynet.co.il · English"),
            .info("Always English (you chose this)"),
            .action("Always Use English on news.ynet.co.il", .unpinCurrent, checked: true),
            .action("Forget Rule for news.ynet.co.il", .forgetCurrent),
            dont(),
        ])
    }

    func testBrowserRuleApplies() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], current: IDs.abc), [
            .header("ynet.co.il · English"),
            .info("The browser's language"),
            .action("Always Use English on ynet.co.il", .pinCurrent),
            .action("Forget Rule for ynet.co.il", .forgetCurrent, enabled: false),
            dont(),
        ])
        XCTAssertEqual(lines([.app(zen, IDs.abc)])[1], .info("The browser's language"), "learned browser rule too")
    }

    func testDefault() {
        XCTAssertEqual(lines([], defaultBehavior: .switchTo(IDs.abc), current: IDs.abc)[0...1], [
            .header("ynet.co.il · English"),
            .info("No rule yet, so the default applies"),
        ])
    }

    func testNoRule() {
        XCTAssertEqual(lines([]), [
            .header("ynet.co.il · Hebrew"),
            .info("No rule yet"),
            .action("Always Use Hebrew on ynet.co.il", .pinCurrent),
            .action("Forget Rule for ynet.co.il", .forgetCurrent, enabled: false),
            dont(),
        ])
    }

    func testPrivateWindow() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], private: true)[0], .header("ynet.co.il · Hebrew (private)"))
        XCTAssertEqual(lines([], private: nil)[0], .header("ynet.co.il · Hebrew"), "unknown is not private")
        XCTAssertEqual(lines([], private: false)[0], .header("ynet.co.il · Hebrew"))
    }

    func testNotAWebPageUsesTheAppForm() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], host: nil, domain: nil, page: .notWebPage,
                             current: IDs.abc), [
            .header("Zen · English"),
            .info("Always English (you chose this)"),
            .action("Always Use English in Zen", .unpinCurrent, checked: true),
            .action("Forget Rule for Zen", .forgetCurrent),
            dont(),
        ])
    }

    func testUnknownWithNoSiteUsesTheAppForm() {
        XCTAssertEqual(lines([], host: nil, domain: nil, page: .unknown)[0...3], [
            .header("Zen · Hebrew"),
            .info("No rule yet"),
            .action("Always Use Hebrew in Zen", .pinCurrent),
            .action("Forget Rule for Zen", .forgetCurrent, enabled: false),
        ])
    }

    func testUnknownOrEditingWithAKeptSiteUsesTheSiteForm() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .unknown)[0], .header("ynet.co.il · Hebrew"))
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .editingAddress)[3],
                       .action("Forget Rule for ynet.co.il", .forgetCurrent))
    }

    func testNoPageStateMeansNoSiteForm() {
        // pageState nil = not a watched browser: the app form.
        XCTAssertEqual(lines([], private: true, page: nil)[0], .header("ynet.co.il · Hebrew"), "no (private) marker")
        XCTAssertTrue(lines([], page: nil)[2].title.hasSuffix(" in ynet.co.il"), "the app form says in, not on")
    }

    // MARK: - Unicode display (D13)

    func testPunycodeHostsAreShownInUnicode() {
        let idn = "xn--9dbne9b.co.il"
        XCTAssertEqual(lines([site(idn, IDs.hebrew)], host: "www." + idn, domain: idn)[0...3], [
            .header("שלום.co.il · Hebrew"),
            .info("Remembered from your switches"),
            .action("Always Use Hebrew on שלום.co.il", .pinCurrent),
            .action("Forget Rule for שלום.co.il", .forgetCurrent),
        ])
    }

    func testAnOldUnicodeRuleIsStillCheckedAsThePin() {
        let idn = "xn--9dbne9b.co.il"
        let out = lines([site("שלום.co.il", IDs.hebrew, .pinned)], host: "www." + idn, domain: idn)
        XCTAssertEqual(out[2], .action("Always Use Hebrew on שלום.co.il", .unpinCurrent, checked: true))
    }

    func testScopeNameShowsUnicode() {
        let app: (String) -> String = { _ in "X" }
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "xn--9dbne9b.co.il"), appName: app), "שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.siteHost(host: "www.xn--9dbne9b.co.il"), appName: app), "www.שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "Ynet.co.il."), appName: app), "ynet.co.il")
    }

    func testNoCurrentSourceDisablesPinOnASite() {
        XCTAssertEqual(lines([], current: nil)[2],
                       .action("Always Use This Language on ynet.co.il", .pinCurrent, enabled: false))
    }
}
