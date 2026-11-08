// P3-29: the address-bar resolution (RuleEngine) and the pair's Latin member (`AddressBarLanguage`). In a browser's
// address bar: the browser's app rule, else the Latin member of the pair ("English"); site rules only in pages.
// The switch off gives the old order back.

import XCTest

final class AddressBarRulesTests: XCTestCase {
    private let zen = "app.zen-browser.zen"
    private let date = Date(timeIntervalSince1970: 5_000)

    private func site(_ domain: String, _ source: InputSourceID) -> Rule {
        Rule(scope: .site(domain: domain), inputSource: source, origin: .learned, updatedAt: date)
    }

    private func host(_ host: String, _ source: InputSourceID) -> Rule {
        Rule(scope: .siteHost(host: host), inputSource: source, origin: .pinned, updatedAt: date)
    }

    private func app(_ source: InputSourceID, _ origin: RuleOrigin = .learned) -> Rule {
        Rule(scope: .app(bundleID: zen), inputSource: source, origin: origin, updatedAt: date)
    }

    private func context(_ state: BrowserPageState?, private isPrivate: Bool? = nil) -> Context {
        Context(bundleID: zen, pid: 7, host: "www.ynet.co.il", siteDomain: "ynet.co.il", isPrivateWindow: isPrivate,
                pageState: state, generation: 1)
    }

    private func engine(_ rules: [Rule], on: Bool = true, latin: InputSourceID? = IDs.abc,
                        defaultBehavior: DefaultBehavior = .keepCurrent, ignorePrivate: Bool = false) -> RuleEngine {
        RuleEngine(rules: rules, defaultBehavior: defaultBehavior, ignorePrivateWindowsCompletely: ignorePrivate,
                   addressBarUsesBrowserLanguage: on, addressBarSource: latin)
    }

    // MARK: - RuleEngine

    func testTheAddressBarUsesTheBrowsersAppRule() {
        let e = engine([app(IDs.russian), site("ynet.co.il", IDs.hebrew), host("www.ynet.co.il", IDs.hebrew)])
        let r = e.resolve(context(.editingAddress))
        XCTAssertEqual(r.target, IDs.russian)
        XCTAssertEqual(r.level, .app)
        XCTAssertEqual(e.resolve(context(.page)).target, IDs.hebrew, "the page still uses the site's rule")
    }

    func testWithoutAnAppRuleTheAddressBarIsEnglish() {
        let e = engine([site("ynet.co.il", IDs.hebrew)], defaultBehavior: .switchTo(IDs.hebrew))
        let r = e.resolve(context(.editingAddress))
        XCTAssertEqual(r.target, IDs.abc)
        XCTAssertEqual(r.level, .addressBar)
        XCTAssertNil(r.matched)
    }

    func testAPinnedAppRuleAndAPinnedSiteRule() {
        let e = engine([app(IDs.russian, .pinned),
                        Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .pinned,
                             updatedAt: date)])
        XCTAssertEqual(e.resolve(context(.editingAddress)).target, IDs.russian)
        XCTAssertEqual(e.resolve(context(.page)).target, IDs.hebrew)
    }

    func testNoLatinMemberFallsBackToTheDefault() {
        let keep = engine([site("ynet.co.il", IDs.hebrew)], latin: nil)
        XCTAssertNil(keep.resolve(context(.editingAddress)).target, "keepCurrent: the site rule doesn't apply in the bar")
        let switchTo = engine([], latin: nil, defaultBehavior: .switchTo(IDs.russian))
        XCTAssertEqual(switchTo.resolve(context(.editingAddress)).level, .defaultRule)
    }

    func testTheSwitchOffKeepsTheOldOrder() {
        let e = engine([app(IDs.russian), site("ynet.co.il", IDs.hebrew)], on: false)
        XCTAssertEqual(e.resolve(context(.editingAddress)).target, IDs.hebrew)
        XCTAssertFalse(e.usesBrowserLanguage(context(.editingAddress)))
    }

    func testOnlyTheAddressBarStateCounts() {
        let e = engine([site("ynet.co.il", IDs.hebrew)])
        for state in [BrowserPageState.page, .unknown, .notWebPage] {
            XCTAssertFalse(e.usesBrowserLanguage(context(state)), "\(state)")
        }
        XCTAssertFalse(e.usesBrowserLanguage(context(nil)), "not a watched browser")
        XCTAssertEqual(e.resolve(context(.unknown)).target, IDs.hebrew, "a kept site still applies outside the bar")
    }

    func testPrivateWindowsGetTheSame() {
        let e = engine([site("ynet.co.il", IDs.hebrew)])
        XCTAssertEqual(e.resolve(context(.editingAddress, private: true)).target, IDs.abc)
        let ignoring = engine([app(IDs.russian), site("ynet.co.il", IDs.hebrew)], ignorePrivate: true)
        XCTAssertEqual(ignoring.resolve(context(.editingAddress, private: true)).target, IDs.russian)
    }

    func testTheLearnerNeverLearnsInTheAddressBarNotEvenTheAppRule() {
        // P3-9 guard (D2), checked again for P3-29: a manual switch in the bar, two words → nothing, at any scope.
        let e = engine([])
        var l = RuleLearner(engine: e, keyboardTapAvailable: true, currentSource: IDs.abc)
        var t: UInt64 = 10_000_000_000
        _ = l.handle(.contextChanged(context(.editingAddress), atNanos: t))
        t += 1_000_000_000
        XCTAssertEqual(l.handle(.externalSwitch(IDs.hebrew, atNanos: t)), .discard(.editingAddress))
        XCTAssertNil(l.handle(.wordBoundary(atNanos: t + 1)))
        XCTAssertNil(l.handle(.wordBoundary(atNanos: t + 2)))
        XCTAssertNil(l.pending)
        // The same with no site at all (a new tab's omnibox): the browser's app rule isn't learned either.
        var noSite = context(.editingAddress)
        noSite.host = nil
        noSite.siteDomain = nil
        _ = l.handle(.contextChanged(noSite, atNanos: t + 3))
        XCTAssertEqual(l.handle(.externalSwitch(IDs.russian, atNanos: t + 2_000_000_000)), .discard(.editingAddress))
    }

    // MARK: - AddressBarLanguage

    private func info(_ id: InputSourceID, _ language: String) -> InputSourceInfo {
        InputSourceInfo(id: id, name: id.rawValue, languageCode: language, isEnabled: true, isConvertible: true,
                        isInputMethod: false)
    }

    func testTheLatinMemberOfThePair() {
        let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        let layouts = [info(IDs.abc, "en"), info(IDs.hebrew, "he")]
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: pair, layouts: layouts), IDs.abc)
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: LanguagePair(a: IDs.hebrew, b: IDs.abc), layouts: layouts),
                       IDs.abc, "order doesn't matter")
    }

    func testOtherScripts() {
        let us = InputSourceID("com.apple.keylayout.US")
        let french = InputSourceID("com.apple.keylayout.French")
        let german = InputSourceID("com.apple.keylayout.German")
        let layouts = [info(us, "en"), info(IDs.russian, "ru"), info(french, "fr"), info(german, "de"),
                       info(IDs.hebrew, "he")]
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: LanguagePair(a: IDs.russian, b: us), layouts: layouts), us)
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: LanguagePair(a: IDs.russian, b: french), layouts: layouts),
                       french, "Latin without English")
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: LanguagePair(a: german, b: us), layouts: layouts), us,
                       "both Latin: the English one")
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: LanguagePair(a: german, b: french), layouts: layouts),
                       german, "both Latin, no English: member A")
        XCTAssertNil(AddressBarLanguage.latinSource(pair: LanguagePair(a: IDs.hebrew, b: IDs.russian),
                                                    layouts: layouts), "no Latin member")
    }

    func testUnlistedABCCountsAsLatinAndImportedMapsSwitchToTheirBase() {
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: .default, layouts: []), IDs.abc)
        let imported = InputSourceID("user.my-english")
        let pair = LanguagePair(a: IDs.hebrew, b: imported)
        let layouts = [info(IDs.hebrew, "he"), info(imported, "en")]
        XCTAssertEqual(AddressBarLanguage.latinSource(pair: pair, layouts: layouts,
                                                      inputSource: { $0 == imported ? IDs.abc : $0 }), IDs.abc)
    }

    func testLatinScriptCodes() {
        for code in ["en", "en-US", "en_GB", "fr", "de", "tr", "pl"] {
            XCTAssertTrue(AddressBarLanguage.isLatinScript(languageCode: code), code)
        }
        for code in ["he", "iw", "ru", "ar", "ja", "el", "", "uk"] {
            XCTAssertFalse(AddressBarLanguage.isLatinScript(languageCode: code), code)
        }
    }

    func testTheSettingIsOnByDefaultAndRoundTrips() throws {
        XCTAssertTrue(Preferences.Browsers().browserLanguageInAddressBar)
        var p = Preferences()
        p.browsers.browserLanguageInAddressBar = false
        let decoded = try PreferencesCodec.decode(PreferencesCodec.encode(p)).0
        XCTAssertFalse(decoded.browsers.browserLanguageInAddressBar)
        let old = try PreferencesCodec.decode(Data(#"{"browsers":{"useAutomation":true}}"#.utf8)).0
        XCTAssertTrue(old.browsers.browserLanguageInAddressBar, "a file from before P3-29 gets it on")
    }
}
