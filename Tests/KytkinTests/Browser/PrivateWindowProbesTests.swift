// P3-16: the per-engine private-window probes (001 §14.4) on fake trees shaped like the owner's probe of normal vs
// private windows (2026-11-08, `docs/research/r3b/p3-16-results/`): Chrome's "(Incognito)" title suffix, Safari's
// "Private Browsing" suffix (P3-30: the `PrivacyReportShieldButton` is no longer a signal), Arc's nearly empty private tree, Zen's nil seam. Also the
// precedence with the P3-7 Apple Event flag, the per-window caching, and the catalog's signal per browser.

import XCTest

final class PrivateWindowProbesTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000
    private let sec: UInt64 = 1_000_000_000
    private var siteReader: SiteReader!
    private var sender: FakeAppleEventSender!
    private var fallback: AppleEventFallback!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
        sender = FakeAppleEventSender()
        let gate = AppleEventSendGate()
        gate.allow(pid: 7)
        fallback = AppleEventFallback(sender: sender, gate: gate)
    }

    // MARK: Trees

    /// A Chromium window with a web area, titled `title` (the window title is page title + suffix).
    private func chromium(title: String?) -> (tree: FakeAXTree, window: Int) {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app, title: title)
        let root = t.add("AXGroup", under: window, domIdentifier: nil)
        let web = t.add("AXWebArea", under: root, url: "https://example.com/a", area: 1000)
        let button = t.add("AXButton", under: web)
        t.main = window
        t.focusedWin = window
        t.focused = button
        return (t, window)
    }

    /// Safari as the owner's probe showed it: a toolbar with id'd buttons at depth 2, the page deeper.
    private func safari(title: String?, shield: Bool) -> (tree: FakeAXTree, window: Int) {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app, identifier: nil, title: title)
        let split = t.add("AXSplitGroup", under: window)
        t.add("AXImage", under: window, identifier: "WindowControlShadowView._shadowImageView")
        let toolbar = t.add("AXToolbar", under: window)
        if shield { t.add("AXButton", under: toolbar, identifier: "PrivacyReportShieldButton") }
        t.add("AXButton", under: toolbar, identifier: "ShareButton")
        t.add("AXButton", under: toolbar, identifier: "NewTabButton")
        let group = t.add("AXGroup", under: toolbar)
        t.add("AXTextField", under: group, identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD", value: "example.net")
        let tabs = t.add("AXTabGroup", under: split)
        let scroll = t.add("AXScrollArea", under: t.add("AXGroup", under: tabs))
        let web = t.add("AXWebArea", under: scroll, url: "https://example.net/", area: 1000)
        t.main = window
        t.focusedWin = window
        t.focused = web
        return (t, window)
    }

    /// Arc's private window in the owner's probe: a window and one split group, nothing else (no web area).
    private func arcPrivate() -> (tree: FakeAXTree, window: Int) {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app, title: "Arc window")
        t.add("AXSplitGroup", under: window)
        t.main = window
        t.focusedWin = window
        t.focused = window
        return (t, window)
    }

    private func probe(_ signal: PrivateWindowSignal, _ tree: FakeAXTree, _ window: Int) throws -> Bool? {
        try PrivateWindowProbes.isPrivate(signal, tree: tree, window: window)
    }

    private func titleReads(_ t: FakeAXTree) -> Int {
        t.calls.filter { if case .string(.title, _) = $0 { true } else { false } }.count
    }

    // MARK: Chromium

    func testChromeIncognitoTitleIsPrivate() throws {
        let c = chromium(title: "Example Domain - Google Chrome (Incognito)")
        XCTAssertEqual(try probe(.chromiumTitle, c.tree, c.window), true)
        XCTAssertEqual(c.tree.calls, [.string(.title, c.window)], "one title read, nothing else")
    }

    func testChromeNormalTitleCantTell() throws {
        let c = chromium(title: "Example Domain - Google Chrome")
        XCTAssertNil(try probe(.chromiumTitle, c.tree, c.window))
    }

    func testChromeTitleThatContainsButDoesNotEndWithTheMarkerCantTell() throws {
        let c = chromium(title: "Using (Incognito) mode safely - Google Chrome")
        XCTAssertNil(try probe(.chromiumTitle, c.tree, c.window))
        let d = chromium(title: "Incognito tips")
        XCTAssertNil(try probe(.chromiumTitle, d.tree, d.window))
    }

    func testChromeHebrewSuffixAndTrailingMarks() throws {
        let c = chromium(title: "דף - Google Chrome (גלישה בסתר)")
        XCTAssertEqual(try probe(.chromiumTitle, c.tree, c.window), true)
        let d = chromium(title: "Example (Incognito)\u{200F} ")
        XCTAssertEqual(try probe(.chromiumTitle, d.tree, d.window), true)
    }

    func testChromeWithNoTitleCantTell() throws {
        let c = chromium(title: nil)
        XCTAssertNil(try probe(.chromiumTitle, c.tree, c.window))
    }

    func testEndsWithAnyIsSuffixOnly() {
        XCTAssertTrue(PrivateWindowProbes.endsWithAny("a (Incognito)", PrivateWindowProbes.chromiumTitleSuffixes))
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("(Incognito) a", PrivateWindowProbes.chromiumTitleSuffixes))
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("", PrivateWindowProbes.chromiumTitleSuffixes))
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("\u{200F}", PrivateWindowProbes.chromiumTitleSuffixes))
        // QA P3-16: bidi controls and no-break spaces after the marker are ignored; anything else isn't.
        let s = PrivateWindowProbes.chromiumTitleSuffixes
        XCTAssertTrue(PrivateWindowProbes.endsWithAny("\u{202B}דף (גלישה בסתר)\u{202C}", s))
        XCTAssertTrue(PrivateWindowProbes.endsWithAny("\u{2067}דף (גלישה בסתר)\u{2069}\u{00A0}\t", s))
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("a (Incognito).", s))
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("a (Incognito)\n", s), "a newline isn't trimmed")
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("דף גלישה בסתר", s), "no parentheses: a page's own words")
        XCTAssertFalse(PrivateWindowProbes.endsWithAny("a (incognito)", s), "case-sensitive, as Chromium writes it")
    }

    // MARK: Safari

    func testSafariShieldButtonAloneIsNotPrivate() throws {
        // P3-30: a normal Safari window with the Privacy Report shield added to its toolbar read as private (owner,
        // 2026-11-08). The shield is no signal any more: one title read, no toolbar scan.
        let s = safari(title: "Example", shield: true)
        XCTAssertNil(try probe(.safari, s.tree, s.window))
        XCTAssertEqual(s.tree.calls, [.string(.title, s.window)])
    }

    func testSafariTitleSuffixAnswersWithoutAToolbarScan() throws {
        // An English private window: one title read (P3-30: whether or not the shield is on the toolbar).
        let s = safari(title: "Example — Private Browsing", shield: true)
        XCTAssertEqual(try probe(.safari, s.tree, s.window), true)
        XCTAssertEqual(s.tree.calls, [.string(.title, s.window)])
    }

    func testSafariNormalWindowCantTell() throws {
        let s = safari(title: "Example", shield: false)
        XCTAssertNil(try probe(.safari, s.tree, s.window))
    }

    func testSafariTitleThatContainsButDoesNotEndWithTheMarkerCantTell() throws {
        let s = safari(title: "Private Browsing explained — Example", shield: false)
        XCTAssertNil(try probe(.safari, s.tree, s.window))
    }

    func testSafariProbeNeverWalksTheTree() throws {
        // P3-30: no identifier scan at all; nothing but the window title is read.
        let s = safari(title: nil, shield: true)
        XCTAssertNil(try probe(.safari, s.tree, s.window))
        XCTAssertEqual(s.tree.calls, [.string(.title, s.window)])
    }

    // MARK: Arc, Zen, none

    func testArcAndZenAndUnknownMakeNoAXCall() throws {
        let c = chromium(title: "Example (Incognito)")
        for signal in [PrivateWindowSignal.arc, .gecko, .none] {
            c.tree.resetCalls()
            XCTAssertNil(try probe(signal, c.tree, c.window), "\(signal)")
            XCTAssertTrue(c.tree.calls.isEmpty, "\(signal)")
        }
    }

    func testZenPrivateWindowReturnsNilThroughTheReader() {
        let zen = BrowserFixtures.zen()
        var r = BrowserAddressReader<FakeAXTree>(request: request(.gecko, signal: .gecko), siteReader: siteReader)
        let o = r.read(zen.tree, now: t0).observation
        XCTAssertNil(o.isPrivate)
        XCTAssertEqual(titleReads(zen.tree), 0)
    }

    // MARK: Through the reader (catalog request, precedence, caching)

    private func request(_ engine: BrowserEngine = .chromium, signal: PrivateWindowSignal,
                         dialect: AppleScriptDialect? = nil, ignorePrivate: Bool = false) -> BrowserWatchRequest {
        BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: ignorePrivate,
                            appleScript: dialect, privateSignal: signal)
    }

    private func reader(_ request: BrowserWatchRequest) -> BrowserAddressReader<FakeAXTree> {
        var r = BrowserAddressReader<FakeAXTree>(request: request, siteReader: siteReader)
        if let d = request.appleScript { r.appleEvents = AppleEventSession(pid: 7, dialect: d, fallback: fallback) }
        return r
    }

    func testChromeIncognitoIsFlaggedAndStillReadUnlessIgnored() {
        let c = chromium(title: "Example (Incognito)")
        var r = reader(request(signal: .chromiumTitle))
        let o = r.read(c.tree, now: t0).observation
        XCTAssertEqual(o.isPrivate, true)
        XCTAssertEqual(o.pageState, .page, "rules still apply in a private window")

        let d = chromium(title: "Example (Incognito)")
        var ignoring = reader(request(signal: .chromiumTitle, ignorePrivate: true))
        let skipped = ignoring.read(d.tree, now: t0).observation
        XCTAssertEqual(skipped, BrowserObservation(site: nil, pageState: .unknown, isPrivate: true, via: .kept))
        XCTAssertFalse(d.tree.calls.contains { if case .url = $0 { true } else { false } }, "D12: no address read")
    }

    func testAXTrueWinsOverTheAppleEventAndNoEventIsSent() {
        let c = chromium(title: "Example (Incognito)")
        sender.privateReplies = [.text("normal")]
        var r = reader(request(signal: .chromiumTitle, dialect: .chromium))
        XCTAssertEqual(r.read(c.tree, now: t0).observation.isPrivate, true)
        XCTAssertEqual(sender.privateSends, 0)
    }

    func testAXNilFallsBackToTheAppleEvent() {
        let c = chromium(title: "Example")   // e.g. Chrome in a language whose suffix isn't listed
        sender.privateReplies = [.text("incognito")]
        var r = reader(request(signal: .chromiumTitle, dialect: .chromium))
        XCTAssertEqual(r.read(c.tree, now: t0).observation.isPrivate, true)
        XCTAssertEqual(sender.privateSends, 1)
    }

    func testProbeRunsOncePerWindowAndATitleChangeKeepsATrue() {
        let c = chromium(title: "Example (Incognito)")
        var r = reader(request(signal: .chromiumTitle))
        _ = r.read(c.tree, now: t0)
        _ = r.read(c.tree, now: t0 + sec)
        XCTAssertEqual(titleReads(c.tree), 1)
        r.noteTrigger(.titleChanged)
        _ = r.read(c.tree, now: t0 + 2 * sec)
        XCTAssertEqual(titleReads(c.tree), 1, "a window can't stop being private: no re-probe")
        r.noteTrigger(.focusedWindowChanged)
        _ = r.read(c.tree, now: t0 + 3 * sec)
        XCTAssertEqual(titleReads(c.tree), 2, "a window change re-probes")
    }

    func testATitleChangeReprobesAWindowThatCouldntTell() {
        let c = chromium(title: "")   // a new window before its title arrives
        var r = reader(request(signal: .chromiumTitle))
        XCTAssertNil(r.read(c.tree, now: t0).observation.isPrivate)
        c.tree.set(c.window) { $0.title = "New Tab (Incognito)" }
        _ = r.read(c.tree, now: t0 + sec)
        XCTAssertEqual(titleReads(c.tree), 1, "cached until a trigger")
        r.noteTrigger(.titleChanged)
        XCTAssertEqual(r.read(c.tree, now: t0 + 2 * sec).observation.isPrivate, true)
    }

    func testATitleChangeReprobesOnlyANewWindow() {
        // QA P3-16: a page whose title keeps changing (a ticker, an unread counter) in a normal window must not
        // re-run the probe on every read: title changes re-probe only while the window has had few probes.
        let s = safari(title: "Example", shield: false)
        var r = reader(request(.webkit, signal: .safari))
        var now = t0
        _ = r.read(s.tree, now: now)
        for _ in 0..<20 {
            r.noteTrigger(.titleChanged)
            now += sec
            _ = r.read(s.tree, now: now)
        }
        XCTAssertEqual(titleReads(s.tree), BrowserReadLimits.titleRecheckProbes)
        XCTAssertEqual(r.windows.first?.privateProbes, BrowserReadLimits.titleRecheckProbes)

        // A window change still re-probes (§14.4), whatever the count.
        r.noteTrigger(.focusedWindowChanged)
        _ = r.read(s.tree, now: now + sec)
        XCTAssertEqual(titleReads(s.tree), BrowserReadLimits.titleRecheckProbes + 1)
    }

    func testANewChromeWindowWhoseTitleArrivesAfterAWindowChangeIsStillCaught() {
        // QA P3-16: attach and a window change both probe before the title arrives; the title change still re-probes.
        let c = chromium(title: "")
        var r = reader(request(signal: .chromiumTitle))
        XCTAssertNil(r.read(c.tree, now: t0).observation.isPrivate)
        r.noteTrigger(.focusedWindowChanged)
        XCTAssertNil(r.read(c.tree, now: t0 + sec).observation.isPrivate)
        c.tree.set(c.window) { $0.title = "New Tab (Incognito)" }
        r.noteTrigger(.titleChanged)
        XCTAssertEqual(r.read(c.tree, now: t0 + 2 * sec).observation.isPrivate, true)
    }

    func testSafariPrivateThroughTheReader() {
        let s = safari(title: "Example - Private Browsing", shield: false)
        var r = reader(request(.webkit, signal: .safari))
        XCTAssertEqual(r.read(s.tree, now: t0).observation.isPrivate, true)
        // P3-30: a normal window with the shield on its toolbar isn't private.
        let n = safari(title: "Example", shield: true)
        var r2 = reader(request(.webkit, signal: .safari))
        XCTAssertNil(r2.read(n.tree, now: t0).observation.isPrivate)
    }

    // MARK: Arc: nothing learned per site, nor at app level

    func testArcPrivateWindowReadsUnknownAndLearnsNothing() {
        let a = arcPrivate()
        var r = reader(request(signal: .arc))
        let (o, sawWindow) = r.read(a.tree, now: t0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertNil(o.site)
        XCTAssertNil(o.isPrivate, "AX can't tell in Arc")
        XCTAssertEqual(titleReads(a.tree), 0)

        // The learner on that Context: the site is unknown, so neither the site nor Arc's app rule is learned (P3-9).
        let arc = "company.thebrowser.Browser"
        let context = Context(bundleID: arc, pid: 7, host: o.site?.host, siteDomain: o.site?.siteKey,
                              isPrivateWindow: o.isPrivate, pageState: o.pageState, generation: 1)
        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        var l = RuleLearner(engine: RuleEngine(rules: []), keyboardTapAvailable: true,
                            currentSource: InputSourceID("com.apple.keylayout.ABC"))
        var t: UInt64 = 10 * sec
        _ = l.handle(.contextChanged(context, atNanos: t))
        t += sec
        var outcome = l.handle(.externalSwitch(hebrew, atNanos: t))
        if outcome == nil {
            _ = l.handle(.wordBoundary(atNanos: t + 1))
            outcome = l.handle(.wordBoundary(atNanos: t + 2))
        }
        XCTAssertEqual(outcome, .discard(.siteUnknown))
    }

    func testArcPrivateWindowWithAutomationIsPrivate() {
        let a = arcPrivate()
        sender.privateReplies = [.flag(true)]
        var r = reader(request(signal: .arc, dialect: .arc))
        XCTAssertEqual(r.read(a.tree, now: t0).observation.isPrivate, true)
        XCTAssertEqual(sender.privateSends, 1)
    }

    // MARK: Catalog

    func testCatalogSignals() {
        let k = BrowserCatalog.known
        XCTAssertEqual(k["com.google.Chrome"]?.privateSignal, .chromiumTitle)
        XCTAssertEqual(k["com.brave.Browser"]?.privateSignal, .chromiumTitle)
        XCTAssertEqual(k["company.thebrowser.Browser"]?.privateSignal, .arc)
        XCTAssertEqual(k["com.apple.Safari"]?.privateSignal, .safari)
        XCTAssertEqual(k["com.apple.SafariTechnologyPreview"]?.privateSignal, .safari)
        XCTAssertEqual(k["com.kagi.kagimacOS"]?.privateSignal, PrivateWindowSignal.none)
        XCTAssertEqual(k["app.zen-browser.zen"]?.privateSignal, .gecko)
        XCTAssertEqual(k["org.mozilla.firefox"]?.privateSignal, .gecko)
    }

    func testSitePolicyCarriesTheSignal() {
        let policy = SitePolicy(availability: browserAvailability(), browsers: Preferences.Browsers(),
                                suffixListLoaded: true, webLinkHandlers: ["com.example.NewBrowser"],
                                ownBundleIDPrefix: "io.github.kytkin.")
        XCTAssertEqual(policy.request(for: "com.google.Chrome")?.privateSignal, .chromiumTitle)
        XCTAssertEqual(policy.request(for: "company.thebrowser.Browser")?.privateSignal, .arc)
        XCTAssertEqual(policy.request(for: "com.apple.Safari")?.privateSignal, .safari)
        XCTAssertEqual(policy.request(for: "app.zen-browser.zen")?.privateSignal, .gecko)
        XCTAssertEqual(policy.request(for: "com.example.NewBrowser")?.privateSignal, PrivateWindowSignal.none)
    }
}
