// P3-29: focus into and out of the address bar, per engine, on fake trees shaped like the R3b / P3-16 dumps. The
// reader must report `.editingAddress` while the bar has focus (that is what makes the browser's language apply),
// keep the page's site, never read the focused bar's text, and go back to `.page` when focus returns to the page.
// Also: the read for a focus move is cheap (no scan), an ignored private window still tells the bar apart, and the
// whole AX-thread path (focus notification → read) runs without the 150 ms debounce.

import XCTest

final class AddressBarFocusTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000
    private let sec: UInt64 = 1_000_000_000
    private var siteReader: SiteReader!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
    }

    private func reader(_ engine: BrowserEngine, signal: PrivateWindowSignal = .none,
                        ignorePrivate: Bool = false) -> BrowserAddressReader<FakeAXTree> {
        BrowserAddressReader<FakeAXTree>(
            request: BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: ignorePrivate,
                                         appleScript: nil, privateSignal: signal),
            siteReader: siteReader)
    }

    private func valueReads(_ t: FakeAXTree, of node: Int) -> Int {
        t.calls.filter { $0 == .string(.value, node) }.count
    }

    private func scans(_ t: FakeAXTree) -> Int {
        t.calls.filter { if case .children = $0 { true } else { false } }.count
    }

    // MARK: - Chrome (omnibox: an AXTextField outside the web area)

    func testChromeOmniboxFocusIsEditingAndBackToThePage() {
        let c = BrowserFixtures.chrome(pageURL: "https://www.ynet.co.il/news")
        var r = reader(.chromium)
        let page = r.read(c.tree, now: t0).observation
        XCTAssertEqual(page.pageState, .page)
        XCTAssertEqual(page.site?.siteKey, "ynet.co.il")

        c.tree.focused = c.omnibox                      // ⌘L
        c.tree.set(c.omnibox) { $0.focused = true }
        c.tree.resetCalls()
        let bar = r.read(c.tree, now: t0 + sec).observation
        XCTAssertEqual(bar.pageState, .editingAddress)
        XCTAssertEqual(bar.site?.siteKey, "ynet.co.il", "the page's site is kept")
        XCTAssertEqual(valueReads(c.tree, of: c.omnibox), 0, "the omnibox text is never read")
        XCTAssertEqual(scans(c.tree), 0, "a focus move reads cached handles only (B13 cached path)")
        XCTAssertLessThanOrEqual(c.tree.calls.count, 12)

        c.tree.focused = c.pageButton                   // click back into the page
        c.tree.set(c.omnibox) { $0.focused = false }
        XCTAssertEqual(r.read(c.tree, now: t0 + 2 * sec).observation.pageState, .page)
    }

    func testChromeNewTabWithTheOmniboxFocusedIsEditingWithoutASite() {
        let c = BrowserFixtures.chrome(omniboxFocused: true)   // ⌘T: chrome://newtab/, focus in the omnibox
        var r = reader(.chromium)
        let o = r.read(c.tree, now: t0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertNil(o.site)
    }

    // MARK: - Arc (⌘L opens the command bar)

    func testArcCommandBarFocusIsEditing() {
        // [I] Arc's ⌘L opens a command bar whose text field isn't in the page. Modelled as a field in a floating
        // panel window (the main window stays the browser window); the owner's checklist §P3-29 confirms it.
        let a = BrowserFixtures.arc(pageURL: "https://www.ynet.co.il/")
        var r = reader(.chromium, signal: .arc)
        XCTAssertEqual(r.read(a.tree, now: t0).observation.pageState, .page)

        let app = a.tree.add("AXApplication")
        let panel = a.tree.add("AXWindow", subrole: "AXFloatingWindow", under: app)
        let field = a.tree.add("AXTextField", under: a.tree.add("AXGroup", under: panel), value: "",
                               focused: true)
        a.tree.focused = field
        a.tree.focusedWin = panel
        a.tree.resetCalls()
        let bar = r.read(a.tree, now: t0 + sec).observation
        XCTAssertEqual(bar.pageState, .editingAddress)
        XCTAssertEqual(bar.site?.siteKey, "ynet.co.il")
        XCTAssertEqual(valueReads(a.tree, of: field), 0)

        a.tree.focused = a.focusedButton
        a.tree.focusedWin = a.window
        XCTAssertEqual(r.read(a.tree, now: t0 + 2 * sec).observation.pageState, .page)
    }

    // MARK: - Safari (the address-and-search field)

    func testSafariAddressFieldFocusIsEditingAndBackToThePage() {
        let s = BrowserFixtures.safari(pageURL: "https://www.ynet.co.il/home")
        var r = reader(.webkit, signal: .safari)
        XCTAssertEqual(r.read(s.tree, now: t0).observation.pageState, .page)

        s.tree.focused = s.addressField
        s.tree.set(s.addressField) { $0.focused = true }
        s.tree.resetCalls()
        let bar = r.read(s.tree, now: t0 + sec).observation
        XCTAssertEqual(bar.pageState, .editingAddress)
        XCTAssertEqual(bar.site?.siteKey, "ynet.co.il")
        XCTAssertEqual(valueReads(s.tree, of: s.addressField), 0, "Safari's field is never read")
        XCTAssertEqual(scans(s.tree), 0)

        s.tree.focused = s.webArea
        s.tree.set(s.addressField) { $0.focused = false }
        XCTAssertEqual(r.read(s.tree, now: t0 + 2 * sec).observation.pageState, .page)
    }

    // MARK: - Zen (Gecko: `urlbar-input` is browser chrome, outside the web area)

    func testZenUrlbarFocusIsSeenByTheFocusWalkAndNeverRead() {
        let z = BrowserFixtures.zen(focus: .page, pageURL: "https://www.ynet.co.il/a")
        var r = reader(.gecko, signal: .gecko)
        let page = r.read(z.tree, now: t0).observation
        XCTAssertEqual(page.pageState, .page)
        XCTAssertEqual(page.site?.siteKey, "ynet.co.il")

        // The walk from the focused urlbar climbs to the window without meeting a web area: an editing role.
        let walk = try? BrowserAddressReader<FakeAXTree>.walkFocus(z.urlbar, window: z.window, knownTopWebArea: nil,
                                                                   tree: z.tree)
        XCTAssertEqual(walk?.focusClass, .editing)

        z.tree.focused = z.urlbar                        // ⌘L
        z.tree.set(z.urlbar) { $0.focused = true }
        z.tree.resetCalls()
        let bar = r.read(z.tree, now: t0 + sec).observation
        XCTAssertEqual(bar.pageState, .editingAddress)
        XCTAssertEqual(bar.site?.siteKey, "ynet.co.il", "the page's site is kept")
        XCTAssertEqual(valueReads(z.tree, of: z.urlbar), 0, "a focused bar's value is never read")
        XCTAssertEqual(scans(z.tree), 0)

        z.tree.focused = z.webArea                       // click back into the page
        z.tree.set(z.urlbar) { $0.focused = false }
        XCTAssertEqual(r.read(z.tree, now: t0 + 2 * sec).observation.pageState, .page)
    }

    func testZenUrlbarFocusedOnTheFirstReadIsEditing() {
        let z = BrowserFixtures.zen(focus: .urlbar)
        var r = reader(.gecko, signal: .gecko)
        let o = r.read(z.tree, now: t0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertNil(o.site, "a new window has nothing kept")
        XCTAssertEqual(valueReads(z.tree, of: z.urlbar), 0)
    }

    // MARK: - Private windows

    func testAnIgnoredPrivateWindowStillTellsTheAddressBarApart() {
        // "Don't use website rules in private windows" on: the address is never read (D12), but the focus class is
        // (no address involved), so the bar of a private window also gets the browser's language.
        let c = BrowserFixtures.chrome(pageURL: "https://www.ynet.co.il/")
        c.tree.set(c.window) { $0.title = "ynet - Google Chrome (Incognito)" }
        var r = reader(.chromium, signal: .chromiumTitle, ignorePrivate: true)
        XCTAssertEqual(r.read(c.tree, now: t0).observation,
                       BrowserObservation(site: nil, pageState: .unknown, isPrivate: true, via: .kept))
        c.tree.focused = c.omnibox
        c.tree.resetCalls()
        XCTAssertEqual(r.read(c.tree, now: t0 + sec).observation,
                       BrowserObservation(site: nil, pageState: .editingAddress, isPrivate: true, via: .kept))
        XCTAssertFalse(c.tree.calls.contains { if case .url = $0 { true } else { false } }, "D12: no address read")
    }

    func testAPrivateWindowThatIsReadReportsTheBarToo() {
        let s = BrowserFixtures.safari(pageURL: "https://www.ynet.co.il/")
        s.tree.set(s.window) { $0.title = "ynet — Private Browsing" }
        var r = reader(.webkit, signal: .safari)
        s.tree.focused = s.addressField
        let o = r.read(s.tree, now: t0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertEqual(o.isPrivate, true)
    }
}
