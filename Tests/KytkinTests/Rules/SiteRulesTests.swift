// P3-9: rules and learning on sites (001 §14.6): a site or host rule beats the browser's app rule (pinned or not),
// `pinScope` vs `learnableScope` (private windows, owner Q1), the learner's page-state guards (D2, D3), Punycode keys
// on write (D13) with old Unicode keys still matching and healing, duplicates collapsing (S3), and
// `browsers.siteRulesEnabled` in preferences.json (§4.2) and SitePolicy.

import XCTest

final class SiteRulesTests: XCTestCase {
    private let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
    private let abc = InputSourceID("com.apple.keylayout.ABC")
    private let zen = "app.zen-browser.zen"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let sec: UInt64 = 1_000_000_000
    /// "שלום.co.il" in Punycode (HostNormalizer).
    private let idnUnicode = "שלום.co.il"
    private let idnPunycode = "xn--9dbne9b.co.il"

    private func rule(_ scope: RuleScope, _ source: InputSourceID, _ origin: RuleOrigin = .learned,
                      at offset: TimeInterval = 0, id: UUID = UUID()) -> Rule {
        Rule(id: id, scope: scope, inputSource: source, origin: origin, updatedAt: t0.addingTimeInterval(offset))
    }

    private func site(_ host: String = "www.ynet.co.il", _ domain: String = "ynet.co.il", private isPrivate: Bool? = nil,
                      page: BrowserPageState? = .page) -> Context {
        Context(bundleID: zen, pid: 7, host: host, siteDomain: domain, isPrivateWindow: isPrivate, pageState: page,
                generation: 1)
    }

    private func noSite(_ page: BrowserPageState?, private isPrivate: Bool? = nil) -> Context {
        Context(bundleID: zen, pid: 7, isPrivateWindow: isPrivate, pageState: page, generation: 1)
    }

    // MARK: - Precedence: site beats the browser pin

    func testLearnedSiteRuleBeatsAPinnedBrowser() {
        let e = RuleEngine(rules: [rule(.app(bundleID: zen), abc, .pinned), rule(.site(domain: "ynet.co.il"), hebrew)])
        let r = e.resolve(site())
        XCTAssertEqual(r.level, .site)
        XCTAssertEqual(r.target, hebrew)
    }

    func testPinnedHostOverrideBeatsSiteAndPinnedBrowser() {
        let e = RuleEngine(rules: [rule(.app(bundleID: zen), abc, .pinned),
                                   rule(.site(domain: "ynet.co.il"), hebrew, .pinned),
                                   rule(.siteHost(host: "news.ynet.co.il"), abc)])
        XCTAssertEqual(e.resolve(site("news.ynet.co.il")).level, .siteHost)
        XCTAssertEqual(e.resolve(site("www.ynet.co.il")).level, .site, "the override covers only its host")
    }

    func testBrowserPinIsTheDefaultForSitesWithoutARule() {
        let e = RuleEngine(rules: [rule(.app(bundleID: zen), abc, .pinned), rule(.site(domain: "ynet.co.il"), hebrew)])
        let r = e.resolve(site("www.haaretz.co.il", "haaretz.co.il"))
        XCTAssertEqual(r.level, .app)
        XCTAssertEqual(r.target, abc)
        XCTAssertEqual(e.resolve(noSite(.notWebPage)).level, .app)
    }

    func testPrivateWindowStillGetsSiteRulesUnlessIgnored() {
        let rules = [rule(.app(bundleID: zen), abc, .pinned), rule(.site(domain: "ynet.co.il"), hebrew)]
        XCTAssertEqual(RuleEngine(rules: rules).resolve(site(private: true)).level, .site)
        XCTAssertEqual(RuleEngine(rules: rules, ignorePrivateWindowsCompletely: true).resolve(site(private: true)).level,
                       .app)
    }

    // MARK: - pinScope and learnableScope

    func testPinScopeOnASite() {
        let e = RuleEngine(rules: [])
        XCTAssertEqual(e.pinScope(for: site()), .site(domain: "ynet.co.il"))
        XCTAssertEqual(e.learnableScope(for: site()), .site(domain: "ynet.co.il"))
    }

    func testPinScopeUsesAnExistingHostOverrideButNeverCreatesOne() {
        let e = RuleEngine(rules: [rule(.siteHost(host: "news.ynet.co.il"), abc, .pinned)])
        XCTAssertEqual(e.pinScope(for: site("news.ynet.co.il")), .siteHost(host: "news.ynet.co.il"))
        XCTAssertEqual(e.pinScope(for: site("sport.ynet.co.il")), .site(domain: "ynet.co.il"))
        XCTAssertEqual(RuleEngine(rules: []).pinScope(for: site("news.ynet.co.il")), .site(domain: "ynet.co.il"))
    }

    func testPinScopeInAPrivateWindowIsTheSiteButLearningIsAppLevelOnly() {
        // Owner Q1: Pin works in private windows (the click is consent); learning never happens there (the learner
        // guard), and learnableScope keeps its app-level answer.
        let e = RuleEngine(rules: [])
        XCTAssertEqual(e.pinScope(for: site(private: true)), .site(domain: "ynet.co.il"))
        XCTAssertEqual(e.learnableScope(for: site(private: true)), .app(bundleID: zen))
    }

    func testPinScopeWithoutASiteIsTheApp() {
        let e = RuleEngine(rules: [])
        XCTAssertEqual(e.pinScope(for: noSite(.notWebPage)), .app(bundleID: zen))
        XCTAssertEqual(e.pinScope(for: noSite(.unknown)), .app(bundleID: zen))
    }

    func testPinScopeIsPunycode() {
        let e = RuleEngine(rules: [])
        XCTAssertEqual(e.pinScope(for: site(idnUnicode, idnUnicode)), .site(domain: idnPunycode))
        XCTAssertEqual(e.pinScope(for: site("WWW.Ynet.co.il.", "Ynet.CO.il.")), .site(domain: "ynet.co.il"))
    }

    // MARK: - Learner guards

    private func learner(_ rules: [Rule] = []) -> RuleLearner {
        RuleLearner(engine: RuleEngine(rules: rules), keyboardTapAvailable: true, currentSource: abc)
    }

    /// Enters `c`, waits past the settle, switches to `id` and types two words.
    private func learn(_ c: Context, _ id: InputSourceID, _ l: inout RuleLearner) -> LearnOutcome? {
        var t: UInt64 = 10 * sec
        _ = l.handle(.contextChanged(c, atNanos: t))
        t += sec
        if let o = l.handle(.externalSwitch(id, atNanos: t)) { return o }
        _ = l.handle(.wordBoundary(atNanos: t + 1))
        return l.handle(.wordBoundary(atNanos: t + 2))
    }

    func testLearnsTheSiteInABrowserPinnedToAnotherLanguage() {
        var l = learner([rule(.app(bundleID: zen), abc, .pinned)])
        XCTAssertEqual(learn(site(), hebrew, &l), .learn(.site(domain: "ynet.co.il"), hebrew))
    }

    func testAPinnedSiteIsNotChangedByLearning() {
        var l = learner([rule(.site(domain: "ynet.co.il"), abc, .pinned)])
        XCTAssertEqual(learn(site(), hebrew, &l), .discard(.pinned))
    }

    func testLearnsIntoAnExistingHostOverride() {
        var l = learner([rule(.siteHost(host: "news.ynet.co.il"), abc)])
        XCTAssertEqual(learn(site("news.ynet.co.il"), hebrew, &l), .learn(.siteHost(host: "news.ynet.co.il"), hebrew))
    }

    func testNothingIsLearnedWhileEditingTheAddress() {
        var l = learner()
        XCTAssertEqual(learn(site(page: .editingAddress), hebrew, &l), .discard(.editingAddress))
        var m = learner()
        XCTAssertEqual(learn(noSite(.editingAddress), hebrew, &m), .discard(.editingAddress))
    }

    func testNothingIsLearnedOnAnUnknownPage() {
        var l = learner()
        XCTAssertEqual(learn(site(page: .unknown), hebrew, &l), .discard(.siteUnknown), "kept site, still unknown")
        var m = learner()
        XCTAssertEqual(learn(noSite(.unknown), hebrew, &m), .discard(.siteUnknown), "never the browser's app rule")
    }

    func testAPageWithoutASiteLearnsNothing() {
        var l = learner()
        XCTAssertEqual(learn(noSite(.page), hebrew, &l), .discard(.siteUnknown))
        var m = learner()
        XCTAssertEqual(learn(site("", "", page: .page), hebrew, &m), .discard(.siteUnknown))
    }

    func testANonWebPageLearnsAtAppLevel() {
        var l = learner()
        XCTAssertEqual(learn(noSite(.notWebPage), hebrew, &l), .learn(.app(bundleID: zen), hebrew))
    }

    func testAnAppThatIsNoWatchedBrowserLearnsAsBefore() {
        var l = learner()
        let notes = Context(bundleID: "com.apple.Notes", pid: 9, generation: 1)
        XCTAssertEqual(learn(notes, hebrew, &l), .learn(.app(bundleID: "com.apple.Notes"), hebrew))
    }

    func testNothingIsLearnedInAPrivateWindowEvenOnAPage() {
        var l = learner()
        XCTAssertEqual(learn(site(private: true), hebrew, &l), .discard(.privateWindow))
        var m = learner()
        XCTAssertEqual(learn(noSite(.notWebPage, private: true), hebrew, &m), .discard(.privateWindow))
    }

    func testUnknownPrivateFlagCountsAsNotPrivate() {
        var l = learner()
        XCTAssertEqual(learn(site(private: nil), hebrew, &l), .learn(.site(domain: "ynet.co.il"), hebrew))
    }

    func testAPageStateChangeBeforeTheCommitDropsTheCandidate() {
        var l = learner()
        _ = l.handle(.contextChanged(site(), atNanos: 10 * sec))
        XCTAssertNil(l.handle(.externalSwitch(hebrew, atNanos: 11 * sec)))
        XCTAssertNotNil(l.pending)
        XCTAssertEqual(l.handle(.contextChanged(site(page: .editingAddress), atNanos: 12 * sec)),
                       .discard(.contextChanged))
        XCTAssertNil(l.pending)
    }

    // MARK: - Punycode on write (D13), duplicates (S3)

    func testLearnWritesASiteInPunycode() {
        let out = RuleWriter.learn(.learn(.site(domain: idnUnicode), hebrew), into: [], now: t0)
        XCTAssertEqual(out.map(\.scope), [.site(domain: idnPunycode)])
        let host = RuleWriter.learn(.learn(.siteHost(host: "News.Ynet.co.il."), hebrew), into: [], now: t0)
        XCTAssertEqual(host.map(\.scope), [.siteHost(host: "news.ynet.co.il")])
    }

    func testPinWritesASiteInPunycode() {
        let out = RuleWriter.pin(.site(domain: "שלום.CO.IL"), to: hebrew, in: [], now: t0)
        XCTAssertEqual(out.map(\.scope), [.site(domain: idnPunycode)])
        XCTAssertEqual(out.first?.origin, .pinned)
    }

    func testAnOldUnicodeRuleStillMatchesAndHealsOnTheNextWrite() {
        let id = UUID()
        let old = [rule(.site(domain: idnUnicode), abc, id: id)]
        let c = site("www." + idnPunycode, idnPunycode)
        XCTAssertEqual(RuleEngine(rules: old).resolve(c).target, abc, "a hand-edited Unicode key still matches")

        let learned = RuleWriter.learn(.learn(.site(domain: idnPunycode), hebrew), into: old, now: t0)
        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.id, id, "updated in place")
        XCTAssertEqual(learned.first?.scope, .site(domain: idnPunycode), "healed to Punycode")
        XCTAssertEqual(learned.first?.inputSource, hebrew)

        let pinned = RuleWriter.pin(.site(domain: idnPunycode), to: hebrew, in: old, now: t0)
        XCTAssertEqual(pinned.map(\.scope), [.site(domain: idnPunycode)])
        XCTAssertEqual(pinned.first?.id, id)
    }

    func testUnicodeAndPunycodeDuplicatesCollapseOnWrite() {
        let keep = UUID()
        let rules = [rule(.app(bundleID: zen), abc),
                     rule(.site(domain: idnUnicode), abc, at: 10, id: keep),
                     rule(.site(domain: idnPunycode + "."), hebrew, at: 0),
                     rule(.site(domain: "ynet.co.il"), hebrew)]
        let out = RuleWriter.pin(.site(domain: idnUnicode), to: hebrew, in: rules, now: t0)
        XCTAssertEqual(out.count, 3)
        let idn = out.filter { $0.scope == .site(domain: idnPunycode) }
        XCTAssertEqual(idn.map(\.id), [keep], "the winner (newer) survives, written in Punycode")
        XCTAssertEqual(idn.first?.origin, .pinned)
        XCTAssertEqual(RuleWriter.forget(.site(domain: idnPunycode), in: rules).count, 2, "forget removes both forms")
    }

    func testAnEmptyLearnedKeyIsNotWritten() {
        XCTAssertEqual(RuleWriter.learn(.learn(.site(domain: "."), hebrew), into: [], now: t0), [])
    }

    func testOverrideHostsAreNormalized() {
        let hosts = RuleEngine.overrideHosts([rule(.siteHost(host: "חדשות.co.il"), abc)])
        XCTAssertEqual(hosts, [HostNormalizer.normalize("חדשות.co.il")])
        XCTAssertTrue(hosts.first?.hasPrefix("xn--") == true)
    }

    // MARK: - browsers.siteRulesEnabled (§4.2)

    private func decode(_ json: String) throws -> PreferencesCodec.Decoded {
        try PreferencesCodec.decodeDetailed(Data(json.utf8))
    }

    func testSiteRulesEnabledDecodesAndRoundTrips() throws {
        let d = try decode(#"{"browsers":{"siteRulesEnabled":{"com.apple.Safari":false,"app.zen-browser.zen":true}}}"#)
        XCTAssertEqual(d.prefs.browsers.siteRulesEnabled, ["com.apple.Safari": false, "app.zen-browser.zen": true])
        XCTAssertFalse(d.isLossy)
        let again = try PreferencesCodec.decode(PreferencesCodec.encode(d.prefs)).0
        XCTAssertEqual(again.browsers.siteRulesEnabled, d.prefs.browsers.siteRulesEnabled)
    }

    func testSiteRulesEnabledAbsentMeansEmpty() throws {
        XCTAssertEqual(try decode("{}").prefs.browsers.siteRulesEnabled, [:])
        XCTAssertEqual(try decode(#"{"browsers":{}}"#).prefs.browsers.siteRulesEnabled, [:])
    }

    func testSiteRulesEnabledIsLenientPerEntry() throws {
        let d = try decode(#"{"browsers":{"siteRulesEnabled":{"com.apple.Safari":false,"com.google.Chrome":"no"},"#
                           + #""ignorePrivateWindowsCompletely":true}}"#)
        XCTAssertEqual(d.prefs.browsers.siteRulesEnabled, ["com.apple.Safari": false], "the bad entry only (= on)")
        XCTAssertTrue(d.prefs.browsers.ignorePrivateWindowsCompletely, "siblings survive")
        XCTAssertTrue(d.isLossy)

        let mistyped = try decode(#"{"browsers":{"siteRulesEnabled":[1,2],"ignorePrivateWindowsCompletely":true}}"#)
        XCTAssertEqual(mistyped.prefs.browsers.siteRulesEnabled, [:])
        XCTAssertTrue(mistyped.prefs.browsers.ignorePrivateWindowsCompletely)
        XCTAssertTrue(mistyped.isLossy)
    }

    func testSitePolicyReadsSiteRulesEnabledFromPreferences() {
        var browsers = Preferences.Browsers()
        browsers.siteRulesEnabled = ["com.apple.Safari": false, zen: true]
        let p = SitePolicy(availability: browserAvailability(), browsers: browsers, suffixListLoaded: true,
                           webLinkHandlers: [], ownBundleIDPrefix: "io.github.kytkin.")
        XCTAssertNil(p.request(for: "com.apple.Safari"), "off → app-only")
        XCTAssertNotNil(p.request(for: zen))
        XCTAssertNotNil(p.request(for: "com.google.Chrome"), "absent = on")
    }
}
