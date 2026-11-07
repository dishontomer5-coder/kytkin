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

    // MARK: - §14.9 rows

    func testSiteRule() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)]), [
            .info("ynet.co.il (Zen): Hebrew (learned)"),
            .action("Always use Hebrew on ynet.co.il", .pinCurrent),
            .action("Forget rule for ynet.co.il", .forgetCurrent),
        ])
    }

    func testPinnedSiteRuleIsChecked() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew, .pinned)]), [
            .info("ynet.co.il (Zen): Hebrew (pinned)"),
            .action("Always use Hebrew on ynet.co.il", .pinCurrent, enabled: false, checked: true),
            .action("Forget rule for ynet.co.il", .forgetCurrent),
        ])
        let other = lines([site("ynet.co.il", IDs.hebrew, .pinned)], current: IDs.abc)
        XCTAssertEqual(other[1], .action("Always use English on ynet.co.il", .pinCurrent), "another language: not done")
    }

    func testHostOverride() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew), host("news.ynet.co.il", IDs.abc)],
                             host: "news.ynet.co.il", current: IDs.abc), [
            .info("news.ynet.co.il (Zen): English (pinned)"),
            .action("Always use English on news.ynet.co.il", .pinCurrent, enabled: false, checked: true),
            .action("Forget rule for news.ynet.co.il", .forgetCurrent),
        ])
    }

    func testBrowserRuleApplies() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], current: IDs.abc), [
            .info("ynet.co.il (Zen): English (Zen's rule)"),
            .action("Always use English on ynet.co.il", .pinCurrent),
            .action("Forget rule for ynet.co.il", .forgetCurrent, enabled: false),
        ])
        XCTAssertEqual(lines([.app(zen, IDs.abc)])[0], .info("ynet.co.il (Zen): English (Zen's rule)"),
                       "learned browser rule too")
    }

    func testDefault() {
        XCTAssertEqual(lines([], defaultBehavior: .switchTo(IDs.abc), current: IDs.abc), [
            .info("ynet.co.il (Zen): English (default)"),
            .action("Always use English on ynet.co.il", .pinCurrent),
            .action("Forget rule for ynet.co.il", .forgetCurrent, enabled: false),
        ])
    }

    func testNoRule() {
        XCTAssertEqual(lines([]), [
            .info("ynet.co.il (Zen): no rule"),
            .action("Always use Hebrew on ynet.co.il", .pinCurrent),
            .action("Forget rule for ynet.co.il", .forgetCurrent, enabled: false),
        ])
    }

    func testPrivateWindow() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], private: true), [
            .info("ynet.co.il (Zen, private): Hebrew (learned)"),
            .action("Always use Hebrew on ynet.co.il", .pinCurrent),
            .action("Forget rule for ynet.co.il", .forgetCurrent),
        ])
        XCTAssertEqual(lines([], private: nil)[0], .info("ynet.co.il (Zen): no rule"), "unknown is not private")
        XCTAssertEqual(lines([], private: false)[0], .info("ynet.co.il (Zen): no rule"))
    }

    func testNotAWebPageUsesTheAppForm() {
        XCTAssertEqual(lines([.app(zen, IDs.abc, .pinned)], host: nil, domain: nil, page: .notWebPage,
                             current: IDs.abc), [
            .info("Zen: English (pinned)"),
            .action("Always use English in Zen", .pinCurrent, enabled: false, checked: true),
            .action("Forget rule for Zen", .forgetCurrent),
        ])
    }

    func testUnknownWithNoSiteUsesTheAppForm() {
        XCTAssertEqual(lines([], host: nil, domain: nil, page: .unknown), [
            .info("Zen: no rule"),
            .action("Always use Hebrew in Zen", .pinCurrent),
            .action("Forget rule for Zen", .forgetCurrent, enabled: false),
        ])
    }

    func testUnknownOrEditingWithAKeptSiteUsesTheSiteForm() {
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .unknown)[0],
                       .info("ynet.co.il (Zen): Hebrew (learned)"))
        XCTAssertEqual(lines([site("ynet.co.il", IDs.hebrew)], page: .editingAddress)[2],
                       .action("Forget rule for ynet.co.il", .forgetCurrent))
    }

    func testNoPageStateMeansNoSiteForm() {
        // pageState nil = not a watched browser: never the "(Browser)" site form.
        XCTAssertFalse(lines([], page: nil)[0].title.contains("(Zen"))
    }

    // MARK: - Unicode display (D13)

    func testPunycodeHostsAreShownInUnicode() {
        let idn = "xn--9dbne9b.co.il"
        XCTAssertEqual(lines([site(idn, IDs.hebrew)], host: "www." + idn, domain: idn), [
            .info("שלום.co.il (Zen): Hebrew (learned)"),
            .action("Always use Hebrew on שלום.co.il", .pinCurrent),
            .action("Forget rule for שלום.co.il", .forgetCurrent),
        ])
    }

    func testAnOldUnicodeRuleIsStillCheckedAsThePin() {
        let idn = "xn--9dbne9b.co.il"
        let out = lines([site("שלום.co.il", IDs.hebrew, .pinned)], host: "www." + idn, domain: idn)
        XCTAssertEqual(out[1], .action("Always use Hebrew on שלום.co.il", .pinCurrent, enabled: false, checked: true))
    }

    func testScopeNameShowsUnicode() {
        let app: (String) -> String = { _ in "X" }
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "xn--9dbne9b.co.il"), appName: app), "שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.siteHost(host: "www.xn--9dbne9b.co.il"), appName: app), "www.שלום.co.il")
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "Ynet.co.il."), appName: app), "ynet.co.il")
    }

    func testNoCurrentSourceDisablesPinOnASite() {
        XCTAssertEqual(lines([], current: nil)[1],
                       .action("Always use this language on ynet.co.il", .pinCurrent, enabled: false))
    }
}
