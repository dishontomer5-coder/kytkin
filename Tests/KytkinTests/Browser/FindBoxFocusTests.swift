// P3-31 (owner decision 2026-11-08): the reader tells the real address bar (`.editingAddress`, the browser's language)
// from the Find box and other toolbar fields (`.editingBrowserField`, the site's language), per browser, on fake trees.
// Zen/Firefox: the cached `urlbar-input` vs the focused element (no AX call), one id read as the fallback. Chrome and
// Safari: wired behind the classifier but gated off (unknown → P3-29). Arc: unknown. Races: a timeout or a vanished
// element during the classification, focus moving between reads. Cost: at most one id read per focus change.

import XCTest

final class FindBoxFocusTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000
    private let sec: UInt64 = 1_000_000_000
    private var siteReader: SiteReader!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
    }

    private func reader(_ engine: BrowserEngine, bar: AddressBarSignal, signal: PrivateWindowSignal = .none,
                        ignorePrivate: Bool = false) -> BrowserAddressReader<FakeAXTree> {
        BrowserAddressReader<FakeAXTree>(
            request: BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: ignorePrivate,
                                         appleScript: nil, privateSignal: signal, addressBarSignal: bar),
            siteReader: siteReader)
    }

    private func idReads(_ t: FakeAXTree, of node: Int) -> Int {
        t.calls.filter { $0 == .string(.domIdentifier, node) || $0 == .string(.identifier, node) }.count
    }

    private func classReads(_ t: FakeAXTree) -> Int {
        t.calls.filter { if case .strings = $0 { true } else { false } }.count
    }

    /// Never AXValue, a title or a description of the focused field.
    private func textReads(_ t: FakeAXTree, of node: Int) -> Int {
        t.calls.filter { $0 == .string(.value, node) || $0 == .string(.title, node) || $0 == .string(.description, node) }
            .count
    }

    /// Zen's find bar: a text field in the content area, outside the web area (Firefox's `findbar`).
    private func addFindBox(_ z: BrowserFixtures.Zen, id: String? = "find-field", role: String = "AXTextField") -> Int {
        let findbar = z.tree.add("AXGroup", under: z.tabPanel)
        return z.tree.add(role, under: findbar, domIdentifier: id, description: "Find in page",
                          value: "secret words")
    }

    // MARK: - Zen (Gecko)

    func testZenUrlbarIsTheBarAndTheFindBoxIsAnotherField() {
        let z = BrowserFixtures.zen(pageURL: "https://www.ynet.co.il/news")
        let find = addFindBox(z)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .page)

        z.tree.focused = z.urlbar                                  // ⌘L
        z.tree.set(z.urlbar) { $0.focused = true }
        let bar = r.read(z.tree, now: t0 + sec).observation
        XCTAssertEqual(bar.pageState, .editingAddress)
        XCTAssertEqual(bar.site?.siteKey, "ynet.co.il")

        z.tree.focused = find                                      // ⌘F
        z.tree.set(z.urlbar) { $0.focused = false }
        z.tree.resetCalls()
        let box = r.read(z.tree, now: t0 + 2 * sec).observation
        XCTAssertEqual(box.pageState, .editingBrowserField)
        XCTAssertEqual(box.site?.siteKey, "ynet.co.il", "the page's site is kept")
        XCTAssertEqual(box.via, .kept)
        XCTAssertEqual(idReads(z.tree, of: find), 1, "one id read for the focus change")
        XCTAssertEqual(textReads(z.tree, of: find), 0, "the Find box's text is never read")
        XCTAssertFalse(z.tree.calls.contains { if case .children = $0 { true } else { false } }, "no scan")

        z.tree.resetCalls()                                        // still typing in the Find box
        XCTAssertEqual(r.read(z.tree, now: t0 + 3 * sec).observation.pageState, .editingBrowserField)
        XCTAssertEqual(idReads(z.tree, of: find), 0, "same focused field: the cached verdict, no AX call")

        z.tree.focused = z.urlbar                                  // back to the bar
        z.tree.set(z.urlbar) { $0.focused = true }
        z.tree.resetCalls()
        XCTAssertEqual(r.read(z.tree, now: t0 + 4 * sec).observation.pageState, .editingAddress)
        XCTAssertEqual(idReads(z.tree, of: z.urlbar), 0, "the cached bar: isSame only")

        z.tree.focused = z.webArea                                 // Esc / click into the page
        z.tree.set(z.urlbar) { $0.focused = false }
        XCTAssertEqual(r.read(z.tree, now: t0 + 5 * sec).observation.pageState, .page)
    }

    func testZenBarNotCachedYetIsFoundByOneIdRead() {
        let z = BrowserFixtures.zen(focus: .urlbar)               // the first read already has focus in the bar
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        let o = r.read(z.tree, now: t0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertEqual(idReads(z.tree, of: z.urlbar), 1)
        XCTAssertEqual(z.tree.calls.filter { $0 == .string(.value, z.urlbar) }.count, 0, "D2: never its value")
        XCTAssertNotNil(r.windows.first?.addressBar, "the bar found by the id read is cached for the window")
    }

    func testZenFindBoxBeforeTheBarIsCached() {
        let z = BrowserFixtures.zen()
        let find = addFindBox(z)
        z.tree.focused = find                                      // the first read: focus already in the Find box
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        let o = r.read(z.tree, now: t0).observation
        XCTAssertEqual(o.pageState, .editingBrowserField, "another id: not the bar")
        XCTAssertNil(r.windows.first?.addressBar)
    }

    func testZenComboBoxWithoutAnIdBeforeTheBarIsCachedKeepsP329() {
        // A Firefox fork whose bar has no id is found only by its description (a combo box): an id-less combo box
        // can't be told apart until the bar is known, so it stays the bar (P3-29).
        let z = BrowserFixtures.zen()
        let find = addFindBox(z, id: nil, role: "AXComboBox")
        z.tree.focused = find
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingAddress)
    }

    func testZenTextFieldWithoutAnIdBeforeTheBarIsCachedIsAnotherField() {
        // QA (P3-31): Firefox's find bar input may have no DOM id. The Gecko bar is always a combo box (by id and by
        // the description fallback), so an id-less text field is not the bar, even in a new window where the bar
        // hasn't been seen yet (checklist §P3-29 step 11.5). The role comes from the focus walk: no extra AX call.
        let z = BrowserFixtures.zen(pageURL: "https://www.ynet.co.il/")
        let find = addFindBox(z, id: nil)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .page)
        XCTAssertNil(r.windows.first?.addressBar, "a page read by AXURL never looks for the bar")
        z.tree.focused = find
        z.tree.resetCalls()
        let o = r.read(z.tree, now: t0 + sec).observation
        XCTAssertEqual(o.pageState, .editingBrowserField)
        XCTAssertEqual(o.site?.siteKey, "ynet.co.il")
        XCTAssertEqual(idReads(z.tree, of: find), 1)
        XCTAssertEqual(z.tree.calls.filter { $0 == .string(.role, find) }.count, 1, "the walk's role read only")
        XCTAssertEqual(textReads(z.tree, of: find), 0)
    }

    func testZenCachedUnknownIsAskedAgainOnceTheBarIsKnown() {
        // QA (P3-31): an id-less combo box cached as "can't tell" must not stay so after the window's bar is found.
        let z = BrowserFixtures.zen()
        let other = addFindBox(z, id: nil, role: "AXComboBox")
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        z.tree.focused = other
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingAddress)
        XCTAssertEqual(r.windows.first?.fieldVerdict?.verdict, .unknown)
        z.tree.resetCalls()
        XCTAssertEqual(r.read(z.tree, now: t0 + sec).observation.pageState, .editingAddress)
        XCTAssertEqual(idReads(z.tree, of: other), 0, "bar still unknown: the cached answer, no AX call")
        z.tree.focused = z.sidebarTab                              // focus in the sidebar: the strategy scans for
        _ = r.read(z.tree, now: t0 + 2 * sec)                      // the bar (no classification: not editing)
        XCTAssertNotNil(r.windows.first?.addressBar)
        XCTAssertEqual(r.windows.first?.fieldVerdict?.verdict, .unknown, "the stale answer is still there")
        z.tree.focused = other                                     // back into the same field
        XCTAssertEqual(r.read(z.tree, now: t0 + 3 * sec).observation.pageState, .editingBrowserField)
        z.tree.resetCalls()
        XCTAssertEqual(r.read(z.tree, now: t0 + 4 * sec).observation.pageState, .editingBrowserField)
        XCTAssertEqual(idReads(z.tree, of: other), 0, "a definite answer stays cached")
    }

    func testZenFieldWithoutAnIdOnceTheBarIsCachedIsAnotherField() {
        let z = BrowserFixtures.zen()
        let find = addFindBox(z, id: nil)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        z.tree.focused = z.urlbar
        z.tree.set(z.urlbar) { $0.focused = true }
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingAddress)
        z.tree.focused = find
        z.tree.set(z.urlbar) { $0.focused = false }
        XCTAssertEqual(r.read(z.tree, now: t0 + sec).observation.pageState, .editingBrowserField)
    }

    func testZenWithoutTheSignalKeepsP329() {
        let z = BrowserFixtures.zen()
        let find = addFindBox(z)
        z.tree.focused = find
        var r = reader(.gecko, bar: .none, signal: .gecko)
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingAddress)
        XCTAssertEqual(idReads(z.tree, of: find), 0, "no classifier: no AX call")
    }

    func testAnIgnoredPrivateZenWindowTellsTheFindBoxApartToo() {
        // D12: the address is never read there, but the focus class and the field's id are (no address involved).
        // Tor Browser's `alwaysPrivate` stands in for a private window (Gecko's AX probe has no signal yet).
        let z = BrowserFixtures.zen(pageURL: "https://www.ynet.co.il/")
        let find = addFindBox(z)
        var r = BrowserAddressReader<FakeAXTree>(
            request: BrowserWatchRequest(engine: .gecko, alwaysPrivate: true, ignorePrivateWindows: true,
                                         appleScript: nil, privateSignal: .gecko, addressBarSignal: .geckoURLBar),
            siteReader: siteReader)
        z.tree.focused = find
        XCTAssertEqual(r.read(z.tree, now: t0).observation,
                       BrowserObservation(site: nil, pageState: .editingBrowserField, isPrivate: true, via: .kept))
        z.tree.focused = z.urlbar
        XCTAssertEqual(r.read(z.tree, now: t0 + sec).observation.pageState, .editingAddress)
        XCTAssertFalse(z.tree.calls.contains { if case .url = $0 { true } else { false } }, "D12: no address read")
        XCTAssertEqual(textReads(z.tree, of: z.urlbar), 0)
    }

    // MARK: - Races (Zen)

    func testATimeoutDuringTheIdReadKeepsP329ForThatReadAndRetriesNextTime() {
        let z = BrowserFixtures.zen(pageURL: "https://www.ynet.co.il/")
        let find = addFindBox(z)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .page)
        z.tree.focused = find
        z.tree.beforeAnswer = { call in
            if call == .string(.domIdentifier, find) { z.tree.hangAfterCalls = 0 }
        }
        let o = r.read(z.tree, now: t0 + sec).observation
        XCTAssertEqual(o.pageState, .editingAddress, "can't tell: P3-29")
        XCTAssertEqual(o.site?.siteKey, "ynet.co.il", "the read itself still stands")
        z.tree.beforeAnswer = nil
        z.tree.hangAfterCalls = nil
        XCTAssertEqual(r.read(z.tree, now: t0 + 2 * sec).observation.pageState, .editingBrowserField,
                       "a failed verdict isn't cached")
    }

    func testTheFindBoxVanishingDuringTheIdReadIsUnknown() {
        let z = BrowserFixtures.zen()
        let find = addFindBox(z)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        z.tree.focused = find
        z.tree.beforeAnswer = { call in
            if call == .string(.domIdentifier, find) { z.tree.errors[find] = .invalidElement }
        }
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingAddress)
        XCTAssertNil(r.windows.first?.fieldVerdict)
    }

    func testFocusMovingFromTheFindBoxToTheBarBetweenReadsIsReclassified() {
        let z = BrowserFixtures.zen()
        let find = addFindBox(z)
        var r = reader(.gecko, bar: .geckoURLBar, signal: .gecko)
        z.tree.focused = find
        XCTAssertEqual(r.read(z.tree, now: t0).observation.pageState, .editingBrowserField)
        z.tree.focused = z.urlbar
        z.tree.set(z.urlbar) { $0.focused = true }
        XCTAssertEqual(r.read(z.tree, now: t0 + 100_000_000).observation.pageState, .editingAddress)
        z.tree.focused = find
        z.tree.set(z.urlbar) { $0.focused = false }
        XCTAssertEqual(r.read(z.tree, now: t0 + 200_000_000).observation.pageState, .editingBrowserField)
    }

    func testASteadyFindBoxStaysTheSameForTheScheduler() {
        // The AX thread posts only on a change of facts: bar → Find box is one, the Find box twice isn't.
        let bar = BrowserObservation(site: nil, pageState: .editingAddress, isPrivate: nil, via: .kept)
        let box = BrowserObservation(site: nil, pageState: .editingBrowserField, isPrivate: nil, via: .kept)
        XCTAssertFalse(bar.hasSameFacts(as: box))
        XCTAssertTrue(box.hasSameFacts(as: box))
    }

    // MARK: - Chrome (Chromium): gated off until the probe

    private func addChromeFindBox(_ c: BrowserFixtures.Chrome, classes: [String]? = ["Textfield", "FindBarView"]) -> Int {
        let findBar = c.tree.add("AXGroup", under: c.window)
        return c.tree.add("AXTextField", under: findBar, domIdentifier: "view_2044", description: "Find",
                          value: "secret", domClassList: classes)
    }

    func testChromeOmniboxAndFindBoxStayTheBarWhileTheClassCheckIsOff() {
        XCTAssertFalse(AddressBarClassifier.chromiumOmniboxClassEnabled, "off until the owner's §P3-31 probe")
        let c = BrowserFixtures.chrome(pageURL: "https://www.ynet.co.il/")
        c.tree.set(c.omnibox) { $0.domClassList = ["OmniboxViewViews"] }
        let find = addChromeFindBox(c)
        var r = reader(.chromium, bar: .chromiumOmniboxClass)
        XCTAssertEqual(r.read(c.tree, now: t0).observation.pageState, .page)
        c.tree.focused = c.omnibox
        XCTAssertEqual(r.read(c.tree, now: t0 + sec).observation.pageState, .editingAddress)
        c.tree.focused = find
        XCTAssertEqual(r.read(c.tree, now: t0 + 2 * sec).observation.pageState, .editingAddress, "unknown: P3-29")
        XCTAssertEqual(classReads(c.tree), 0, "gated off: no class list read at all")
    }

    func testChromeWithTheClassCheckOnTellsTheFindBoxApart() {
        let c = BrowserFixtures.chrome(pageURL: "https://www.ynet.co.il/")
        c.tree.set(c.omnibox) { $0.domClassList = ["OmniboxViewViews"] }
        let find = addChromeFindBox(c)
        var r = reader(.chromium, bar: .chromiumOmniboxClass)
        r.addressBarClassifier = AddressBarClassifier(signal: .chromiumOmniboxClass, chromiumEnabled: true)
        _ = r.read(c.tree, now: t0)
        c.tree.focused = c.omnibox
        c.tree.resetCalls()
        XCTAssertEqual(r.read(c.tree, now: t0 + sec).observation.pageState, .editingAddress)
        XCTAssertEqual(classReads(c.tree), 1)
        c.tree.focused = find
        c.tree.resetCalls()
        let box = r.read(c.tree, now: t0 + 2 * sec).observation
        XCTAssertEqual(box.pageState, .editingBrowserField)
        XCTAssertEqual(box.site?.siteKey, "ynet.co.il")
        XCTAssertEqual(classReads(c.tree), 1, "one class list read per focus change")
        XCTAssertEqual(textReads(c.tree, of: find), 0)
        c.tree.resetCalls()
        _ = r.read(c.tree, now: t0 + 3 * sec)
        XCTAssertEqual(classReads(c.tree), 0, "same field: cached")
    }

    func testChromeWithoutAClassListIsUnknown() {
        let c = BrowserFixtures.chrome(pageURL: "https://www.ynet.co.il/")
        let find = addChromeFindBox(c, classes: nil)
        var r = reader(.chromium, bar: .chromiumOmniboxClass)
        r.addressBarClassifier = AddressBarClassifier(signal: .chromiumOmniboxClass, chromiumEnabled: true)
        c.tree.focused = find
        XCTAssertEqual(r.read(c.tree, now: t0).observation.pageState, .editingAddress)
        c.tree.focused = c.omnibox                                  // no class list either: can't tell
        XCTAssertEqual(r.read(c.tree, now: t0 + sec).observation.pageState, .editingAddress)
    }

    // MARK: - Safari (gated), Arc (none)

    func testSafariFindBoxStaysTheBarWhileTheIdCheckIsOffAndIsToldApartWhenOn() {
        XCTAssertFalse(AddressBarClassifier.safariAddressFieldIDEnabled)
        let s = BrowserFixtures.safari(pageURL: "https://www.ynet.co.il/")
        let find = s.tree.add("AXTextField", under: s.window, identifier: "FIND_BANNER_FIELD")
        var off = reader(.webkit, bar: .safariAddressField, signal: .safari)
        s.tree.focused = find
        XCTAssertEqual(off.read(s.tree, now: t0).observation.pageState, .editingAddress)
        XCTAssertEqual(idReads(s.tree, of: find), 0)

        var on = reader(.webkit, bar: .safariAddressField, signal: .safari)
        on.addressBarClassifier = AddressBarClassifier(signal: .safariAddressField, safariEnabled: true)
        XCTAssertEqual(on.read(s.tree, now: t0 + sec).observation.pageState, .editingBrowserField)
        s.tree.focused = s.addressField
        XCTAssertEqual(on.read(s.tree, now: t0 + 2 * sec).observation.pageState, .editingAddress)
    }

    func testArcCommandBarCantBeToldApart() {
        let a = BrowserFixtures.arc()
        let field = a.tree.add("AXTextField", under: a.window, domClassList: ["Textfield"])
        a.tree.focused = field
        var r = reader(.chromium, bar: BrowserCatalog.known["company.thebrowser.Browser"]!.addressBarSignal)
        XCTAssertEqual(r.read(a.tree, now: t0).observation.pageState, .editingAddress)
        XCTAssertEqual(classReads(a.tree), 0)
    }

    // MARK: - Catalog and request

    func testCatalogSignals() {
        XCTAssertEqual(BrowserCatalog.known["app.zen-browser.zen"]?.addressBarSignal, .geckoURLBar)
        XCTAssertEqual(BrowserCatalog.known["org.mozilla.firefox"]?.addressBarSignal, .geckoURLBar)
        XCTAssertEqual(BrowserCatalog.known["com.google.Chrome"]?.addressBarSignal, .chromiumOmniboxClass)
        XCTAssertEqual(BrowserCatalog.known["company.thebrowser.Browser"]?.addressBarSignal, AddressBarSignal.none)
        XCTAssertEqual(BrowserCatalog.known["com.apple.Safari"]?.addressBarSignal, .safariAddressField)
        XCTAssertEqual(BrowserCatalog.known["com.kagi.kagimacOS"]?.addressBarSignal, AddressBarSignal.none)
    }

    func testThePolicyPassesTheSignalOn() {
        let policy = SitePolicy(availability: browserAvailability(), browsers: Preferences.Browsers(),
                                suffixListLoaded: true,
                                webLinkHandlers: ["app.zen-browser.zen", "com.example.browser"],
                                ownBundleIDPrefix: "io.github.kytkin")
        XCTAssertEqual(policy.request(for: "app.zen-browser.zen")?.addressBarSignal, .geckoURLBar)
        XCTAssertEqual(policy.request(for: "com.example.browser")?.addressBarSignal, AddressBarSignal.none)
    }

    // MARK: - Support tracker

    func testTheFindBoxIsNeitherASuccessNorAFailure() {
        var t = BrowserSupportTracker()
        for _ in 0..<5 {
            t.record(bundleID: "z", BrowserObservation(site: nil, pageState: .editingBrowserField, isPrivate: nil,
                                                       via: .kept), sawWindow: true)
        }
        let request = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                          appleScript: nil)
        XCTAssertEqual(t.status(bundleID: "z", request: request, availability: browserAvailability(),
                                suffixListLoaded: true),
                       .notSeenYet)
    }
}
