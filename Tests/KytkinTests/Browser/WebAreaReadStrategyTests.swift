// P3-11: The Chromium / WebKit / unknown-engine read strategy (001 §14.3.3) on R3b-shaped fake trees, through the
// real `BrowserAddressReader` (prelude, latch, cache). Covers: Arc and Chrome (two web areas, popup focus, devtools
// and picture-in-picture in another window, internal pages), Safari's presumed shape (the address field is never
// read), an unknown browser, a stale handle, a timeout through the latch, and the AX-call budget (B13).

import XCTest

final class WebAreaReadStrategyTests: XCTestCase {
    private typealias Reader = BrowserAddressReader<FakeAXTree>
    private var siteReader: SiteReader!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
    }

    private func reader(_ engine: BrowserEngine = .chromium) -> Reader {
        Reader(request: BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: false,
                                            appleScript: nil),
               siteReader: siteReader)
    }

    private func site(_ host: String, _ domain: String) -> SiteAddress {
        SiteAddress(host: host, registrableDomain: domain, isWebPage: true)
    }

    private func page(_ host: String, _ domain: String) -> BrowserObservation {
        BrowserObservation(site: site(host, domain), pageState: .page, isPrivate: nil, via: .axURL)
    }

    private func urlCalls(_ tree: FakeAXTree) -> [Int] {
        tree.calls.compactMap { if case .url(let n) = $0 { n } else { nil } }
    }

    private func valueCalls(_ tree: FakeAXTree) -> Int {
        tree.calls.filter { if case .string(.value, _) = $0 { true } else { false } }.count
    }

    private func roleCalls(_ tree: FakeAXTree) -> Int {
        tree.calls.filter { if case .string(.role, _) = $0 { true } else { false } }.count
    }

    // MARK: Arc

    func testArcReadsItsWebAreaAtDepthThreeAndCachesIt() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        let (o, sawWindow) = r.read(arc.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, page("example.org", "example.org"))
        XCTAssertEqual(r.windows.first?.webArea, arc.webArea)
        XCTAssertEqual(arc.tree.childrenCalls, 0, "focus in page: no scan")
    }

    func testArcWithFocusOutsideThePageScansOnceThenUsesTheCache() {
        let arc = BrowserFixtures.arc()
        arc.tree.focused = nil
        var r = reader()
        XCTAssertEqual(r.read(arc.tree, now: 0).observation, page("example.org", "example.org"))
        XCTAssertGreaterThan(arc.tree.childrenCalls, 0)
        XCTAssertEqual(r.windows.first?.lastFullScanAt, 0)
        arc.tree.resetCalls()
        XCTAssertEqual(r.read(arc.tree, now: 1).observation, page("example.org", "example.org"))
        XCTAssertEqual(arc.tree.childrenCalls, 0)
    }

    func testInternalPagesAreNotWebPages() {
        for url in ["chrome://newtab/", "about:blank", "arc://settings", "edge://settings/", "chrome-extension://x/y"] {
            let arc = BrowserFixtures.arc(pageURL: url)
            var r = reader()
            XCTAssertEqual(r.read(arc.tree, now: 0).observation,
                           BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL), url)
        }
    }

    // MARK: Chrome

    func testChromePicksTheWebAreaHoldingFocus() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/a", stripURL: "https://example.org/")
        var r = reader()
        XCTAssertEqual(r.read(chrome.tree, now: 0).observation, page("www.example.com", "example.com"))
        XCTAssertEqual(urlCalls(chrome.tree), [chrome.bigWebArea])
        XCTAssertEqual(r.windows.first?.webArea, chrome.bigWebArea)
    }

    func testChromeWithoutFocusInAPagePicksTheLargestWebArea() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/a", stripURL: "https://example.org/")
        chrome.tree.focused = nil
        var r = reader()
        XCTAssertEqual(r.read(chrome.tree, now: 0).observation, page("www.example.com", "example.com"))
        XCTAssertEqual(urlCalls(chrome.tree), [chrome.bigWebArea], "the 56-px strip is never read")
        XCTAssertEqual(r.windows.first?.webArea, chrome.bigWebArea)
    }

    func testChromeLargestWinsWhateverTheOrder() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://example.org/", stripURL: "https://www.example.com/")
        chrome.tree.focused = nil
        chrome.tree.set(chrome.bigWebArea) { $0.area = 10 }   // now the "strip" is the larger one
        var r = reader()
        XCTAssertEqual(r.read(chrome.tree, now: 0).observation, page("www.example.com", "example.com"))
    }

    func testChromeInternalPageIsNotWebPage() {
        let chrome = BrowserFixtures.chrome()   // chrome://newtab/ (R3b)
        var r = reader()
        let o = r.read(chrome.tree, now: 0).observation
        XCTAssertEqual(o, BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL))
    }

    func testChromeFocusInThePopupUsesTheMainWindow() throws {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/a")
        let dialog = try XCTUnwrap(chrome.tree.nodes[chrome.popup]?.children.first)
        chrome.tree.focused = try XCTUnwrap(chrome.tree.nodes[dialog]?.children.first)   // static text in the popup
        var r = reader()
        let (o, sawWindow) = r.read(chrome.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, page("www.example.com", "example.com"))
        XCTAssertEqual(r.windows.first?.window, chrome.window)
        XCTAssertFalse(chrome.tree.calls.contains(.children(chrome.popup)), "the popup is never scanned")
    }

    func testFocusedOmniboxIsEditingWithThePagesSiteAndTheOmniboxIsNeverRead() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/a", omniboxFocused: true)
        var r = reader()
        let o = r.read(chrome.tree, now: 0).observation
        XCTAssertEqual(o, BrowserObservation(site: site("www.example.com", "example.com"), pageState: .editingAddress,
                                             isPrivate: nil, via: .axURL))
        XCTAssertEqual(valueCalls(chrome.tree), 0)
        XCTAssertFalse(chrome.tree.calls.contains(.isFocused(chrome.omnibox)))
    }

    func testOmniboxIsNeverReadByAnyOfTheseEngines() {
        // D16 (unfocused) and D2 (focused), for every engine this strategy serves.
        for engine in [BrowserEngine.chromium, .webkit, .unknown] {
            for focused in [true, false] {
                let chrome = BrowserFixtures.chrome(omniboxFocused: focused)
                chrome.tree.set(chrome.bigWebArea) { $0.url = nil }
                chrome.tree.set(chrome.smallWebArea) { $0.url = nil }
                var r = reader(engine)
                _ = r.read(chrome.tree, now: 0)
                XCTAssertEqual(valueCalls(chrome.tree), 0, "\(engine) \(focused)")
            }
        }
    }

    // MARK: Another window's web area (devtools, picture-in-picture)

    /// Chrome's main window plus a second window with its own web area holding focus.
    private func chromeWithSecondWindow(subrole: String, url: String) -> (BrowserFixtures.Chrome, Int) {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/a")
        let app = chrome.tree.nodes[chrome.window]!.parent!
        let other = chrome.tree.add("AXWindow", subrole: subrole, under: app)
        let group = chrome.tree.add("AXGroup", under: other)
        let otherArea = chrome.tree.add("AXWebArea", under: group, url: url, area: 5_000_000)
        chrome.tree.focused = chrome.tree.add("AXButton", under: otherArea)
        return (chrome, otherArea)
    }

    func testDevtoolsWebAreaInAnotherWindowIsNeitherReadNorCached() {
        let (chrome, devtools) = chromeWithSecondWindow(subrole: "AXStandardWindow",
                                                        url: "devtools://devtools/bundled/inspector.html")
        var r = reader()
        XCTAssertEqual(r.read(chrome.tree, now: 0).observation, page("www.example.com", "example.com"))
        XCTAssertEqual(r.windows.first?.webArea, chrome.bigWebArea)
        XCTAssertFalse(urlCalls(chrome.tree).contains(devtools))
    }

    func testPictureInPictureWebAreaIsNotCachedForTheMainWindow() {
        let (chrome, pip) = chromeWithSecondWindow(subrole: "AXFloatingWindow", url: "https://example.org/video")
        var r = reader()
        _ = r.read(chrome.tree, now: 0)
        XCTAssertEqual(r.windows.first?.webArea, chrome.bigWebArea)
        // Later, with focus back nowhere, the cache still points at the main window's page.
        chrome.tree.focused = nil
        XCTAssertEqual(r.read(chrome.tree, now: 1).observation, page("www.example.com", "example.com"))
        XCTAssertFalse(urlCalls(chrome.tree).contains(pip))
    }

    func testOwnershipWalkIsBounded() throws {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        var parent = window
        for _ in 0..<40 { parent = t.add("AXGroup", under: parent) }
        let deep = t.add("AXWebArea", under: parent, url: "https://example.com/")
        let tree = LatchedAXTree(t, latch: AXReadLatch())
        XCTAssertFalse(try WebAreaReadStrategy<LatchedAXTree<FakeAXTree>>.belongs(deep, to: window, tree: tree))
        let parentCalls = t.calls.filter { if case .parent = $0 { true } else { false } }.count
        XCTAssertEqual(parentCalls, WebAreaReadStrategy<LatchedAXTree<FakeAXTree>>.ownerWalkSteps)
    }

    // MARK: Safari (presumed shape, unverified)

    func testSafariReadsAXURLAndNeverTheAddressField() {
        let safari = BrowserFixtures.safari()
        var r = reader(.webkit)
        XCTAssertEqual(r.read(safari.tree, now: 0).observation, page("example.net", "example.net"))
        XCTAssertEqual(safari.tree.calls(about: safari.addressField), [], "focus in page: the field isn't touched")
        XCTAssertEqual(valueCalls(safari.tree), 0)
    }

    func testSafariFocusedAddressFieldIsEditingWithThePagesSite() {
        let safari = BrowserFixtures.safari(fieldFocused: true)
        var r = reader(.webkit)
        let o = r.read(safari.tree, now: 0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertEqual(o.site, site("example.net", "example.net"))
        XCTAssertEqual(valueCalls(safari.tree), 0)
    }

    func testSafariWithoutAWebAreaIsUnknownAndLeavesTheFieldAlone() {
        // No address-field fallback (Coordinator decision): unknown with a window, so opt-in Automation (P3-7) can act.
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        let toolbar = t.add("AXToolbar", under: window)
        let field = t.add("AXTextField", under: toolbar, identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
                          value: "example.net", focused: false)
        t.main = window
        t.focused = window
        var r = reader(.webkit)
        let (o, sawWindow) = r.read(t, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, .unknown())
        XCTAssertFalse(t.calls.contains(.string(.value, field)))
        XCTAssertFalse(t.calls.contains(.string(.identifier, field)))
        XCTAssertFalse(t.calls.contains(.isFocused(field)))
    }

    // MARK: Unknown engine (best effort)

    func testUnknownBrowserUsesTheWebAreaSearch() {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        let group = t.add("AXGroup", under: window)
        let area = t.add("AXWebArea", under: group, url: "https://docs.example.com/x", area: 800 * 600)
        let input = t.add("AXTextArea", under: area)
        t.main = window
        t.focused = input
        var r = reader(.unknown)
        XCTAssertEqual(r.read(t, now: 0).observation, page("docs.example.com", "example.com"))
        t.focused = nil
        XCTAssertEqual(r.read(t, now: 1).observation, page("docs.example.com", "example.com"))
    }

    func testUnknownBrowserWithoutAWebAreaIsUnknownAndReadsNoTextField() {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        let field = t.add("AXTextField", under: window, description: "Address", value: "https://example.com/")
        t.main = window
        t.focused = nil
        var r = reader(.unknown)
        XCTAssertEqual(r.read(t, now: 0).observation, .unknown())
        t.focused = field
        XCTAssertEqual(r.read(t, now: 3_000_000_000).observation.pageState, .editingAddress)
        XCTAssertEqual(valueCalls(t), 0)
    }

    // MARK: Stale handle

    func testStaleCachedWebAreaIsDroppedAndRescannedInTheSameRead() throws {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        let scroll = try XCTUnwrap(arc.tree.nodes[arc.webArea]?.parent)
        // The tab was replaced: the old handle is invalid, a new web area sits in its place.
        let fresh = arc.tree.add("AXWebArea", under: scroll, url: "https://www.example.com/new", area: 1708 * 1063)
        arc.tree.set(scroll) { $0.children = [fresh] }
        arc.tree.errors[arc.webArea] = .invalidElement
        arc.tree.focused = nil
        let o = r.read(arc.tree, now: 1).observation
        XCTAssertEqual(o, page("www.example.com", "example.com"))
        XCTAssertEqual(r.windows.first?.webArea, fresh)
        XCTAssertEqual(r.windows.first?.lastFullScanAt, 1)
    }

    func testStaleHandleRescanEvenRightAfterAScan() {
        let arc = BrowserFixtures.arc()
        arc.tree.focused = nil
        var r = reader()
        _ = r.read(arc.tree, now: 0)                  // scans at 0 and caches
        XCTAssertEqual(r.windows.first?.lastFullScanAt, 0)
        let scroll = arc.tree.nodes[arc.webArea]!.parent!
        let fresh = arc.tree.add("AXWebArea", under: scroll, url: "https://example.net/", area: 1)
        arc.tree.set(scroll) { $0.children = [fresh] }
        arc.tree.errors[arc.webArea] = .invalidElement
        XCTAssertEqual(r.read(arc.tree, now: 1).observation, page("example.net", "example.net"),
                       "an invalid handle allows one rescan inside the 2 s limit")
    }

    // MARK: Scan limits (B13)

    func testAtMostOneFullScanPerWindowPerTwoSeconds() {
        let chrome = BrowserFixtures.chrome()
        chrome.tree.set(chrome.bigWebArea) { $0.role = "AXGroup" }    // a Chrome with no web area exposed
        chrome.tree.set(chrome.smallWebArea) { $0.role = "AXGroup" }
        chrome.tree.focused = nil
        var r = reader()
        let step: UInt64 = 1_000_000_000
        var scans: [Bool] = []
        for i: UInt64 in 0...4 {
            chrome.tree.resetCalls()
            let (o, sawWindow) = r.read(chrome.tree, now: i * step)
            XCTAssertTrue(sawWindow)
            XCTAssertEqual(o, .unknown())
            scans.append(chrome.tree.childrenCalls > 0)
        }
        XCTAssertEqual(scans, [true, false, true, false, true])
    }

    func testANewWindowMayScanAtOnce() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/")
        chrome.tree.focused = nil
        var r = reader()
        _ = r.read(chrome.tree, now: 0)
        let app = chrome.tree.nodes[chrome.window]!.parent!
        let w2 = chrome.tree.add("AXWindow", subrole: "AXStandardWindow", under: app)
        chrome.tree.add("AXWebArea", under: w2, url: "https://example.org/", area: 100)
        chrome.tree.main = w2
        XCTAssertEqual(r.read(chrome.tree, now: 1).observation, page("example.org", "example.org"))
    }

    func testScanVisitsAtMostFourHundredNodes() {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        for _ in 0..<600 { t.add("AXGroup", under: window) }
        t.add("AXWebArea", under: window, url: "https://example.com/")   // node 602: beyond the limit
        t.main = window
        var r = reader()
        XCTAssertEqual(r.read(t, now: 0).observation, .unknown())
        XCTAssertEqual(roleCalls(t), BrowserReadLimits.scanNodes)
        XCTAssertTrue(urlCalls(t).isEmpty)
    }

    // MARK: Timeout through the latch

    func testTimeoutMidScanStopsTheReadAtOnce() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/")
        chrome.tree.focused = nil
        var r = reader()
        chrome.tree.hangAfterCalls = 6   // the browser hangs mid-scan
        let (o, sawWindow) = r.read(chrome.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, .unknown())
        XCTAssertEqual(chrome.tree.calls.count, 7, "the first timeout ends the read")
    }

    func testTimeoutOnTheCachedWebAreaKeepsTheSiteAndDoesNotScan() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        arc.tree.focused = nil
        arc.tree.errors[arc.webArea] = .timedOut
        arc.tree.resetCalls()
        let o = r.read(arc.tree, now: 5_000_000_000).observation
        XCTAssertEqual(o, .unknown(kept: site("example.org", "example.org")))
        XCTAssertEqual(arc.tree.childrenCalls, 0, "no scan after a timeout")
        XCTAssertEqual(r.windows.first?.webArea, arc.webArea, "a timeout doesn't drop the handle")
    }

    // MARK: AX-call budget (B13)

    func testCachedPollCostsThreeCalls() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        arc.tree.focused = nil
        arc.tree.resetCalls()
        _ = r.read(arc.tree, now: 2_000_000_000)
        XCTAssertEqual(arc.tree.calls, [.focusedElement, .mainWindow, .url(arc.webArea)])
    }

    func testInPageReadsCostOnlyTheFocusWalkOnceCached() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        let first = arc.tree.calls.count
        arc.tree.resetCalls()
        _ = r.read(arc.tree, now: 1)
        let second = arc.tree.calls.count
        // First: 2 app calls + focus walk on to the window (7 roles, 7 parents; it proves ownership, so no second
        // walk) + AXURL.
        XCTAssertEqual(first, 17)
        XCTAssertEqual(second, 11, "the walk stops at the cached web area: 4 roles, 4 parents")
    }

    func testChromeFirstReadWithFullScanStaysSmall() {
        let chrome = BrowserFixtures.chrome(pageURL: "https://www.example.com/")
        chrome.tree.focused = nil
        var r = reader()
        _ = r.read(chrome.tree, now: 0)
        // 12 nodes in the main window: 12 role reads, 10 children calls, 2 area reads, 1 AXURL, 2 app calls.
        XCTAssertLessThanOrEqual(chrome.tree.calls.count, 30)
        XCTAssertEqual(chrome.tree.calls.filter { if case .area = $0 { true } else { false } }.count, 2)
    }
}
