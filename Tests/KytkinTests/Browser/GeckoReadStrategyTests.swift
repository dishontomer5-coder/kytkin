// P3-13: The Gecko (Zen, Firefox) read strategy on the R3b Zen fixtures (001 §14.3.3 "Gecko"): the up-walk, the
// `urlbar-input` scan and cache, "never read a focused bar" asserted from the call log (D2), search terms → unknown
// (D10), `about:` → not web, compact mode without a bar, a stale bar, the timeout latch, the walk bound and the AX
// call budget per read (B13).

import XCTest

final class GeckoReadStrategyTests: XCTestCase {
    private typealias Reader = BrowserAddressReader<FakeAXTree>
    private var siteReader: SiteReader!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
    }

    /// The production path: the engine's default strategy, no private probe yet.
    private func reader() -> Reader {
        Reader(request: BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                            appleScript: nil),
               siteReader: siteReader)
    }

    private let example = SiteAddress(host: "www.example.com", registrableDomain: "example.com", isWebPage: true)
    private let seconds: UInt64 = 1_000_000_000

    private func valueReads(_ tree: FakeAXTree, _ bar: Int) -> Int {
        tree.calls.filter { $0 == .string(.value, bar) }.count
    }

    /// Takes the urlbar out of the toolbar's children (Zen compact mode: the toolbar is hidden).
    private func hideBar(_ zen: BrowserFixtures.Zen) {
        let group = zen.tree.nodes[zen.urlbar]!.parent!
        zen.tree.set(group) { $0.children.removeAll { $0 == zen.urlbar } }
    }

    // MARK: Fixture focus variants

    func testFocusInPageReadsAXURLAndNeverTouchesTheBar() {
        let zen = BrowserFixtures.zen(focus: .page)
        var r = reader()
        let (o, sawWindow) = r.read(zen.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL))
        XCTAssertEqual(zen.tree.calls(about: zen.urlbar), [])
        XCTAssertEqual(zen.tree.childrenCalls, 0, "no scan while the page has focus")
        XCTAssertNil(r.windows[0].webArea, "the Zen web area isn't cached")
        // Budget: 2 app calls + the focus element's role + its AXURL.
        XCTAssertEqual(zen.tree.calls, [.focusedElement, .mainWindow, .string(.role, zen.webArea), .url(zen.webArea)])
    }

    func testFocusInPageDeeperDownWalksUpToTheWebArea() {
        let zen = BrowserFixtures.zen(focus: .page)
        let link = zen.tree.add("AXLink", under: zen.tree.add("AXGroup", under: zen.webArea))
        zen.tree.focused = link
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
    }

    func testFocusInURLBarIsEditingAndItsValueIsNeverRead() {
        let zen = BrowserFixtures.zen(focus: .page)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)

        zen.tree.focused = zen.urlbar
        zen.tree.set(zen.urlbar) { $0.focused = true; $0.value = "typing somethi" }
        zen.tree.resetCalls()
        let o = r.read(zen.tree, now: 1).observation
        XCTAssertEqual(o, BrowserObservation(site: example, pageState: .editingAddress, isPrivate: nil, via: .kept))
        XCTAssertEqual(valueReads(zen.tree, zen.urlbar), 0, "D2: a focused bar's value is never asked for")
        XCTAssertEqual(zen.tree.childrenCalls, 0, "no scan while editing")
    }

    func testFixtureFocusedURLBarFromAFreshReader() {
        let zen = BrowserFixtures.zen(focus: .urlbar)
        var r = reader()
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o, BrowserObservation(site: nil, pageState: .editingAddress, isPrivate: nil, via: .kept))
        XCTAssertEqual(valueReads(zen.tree, zen.urlbar), 0)
    }

    func testFocusOnTheCachedBarAsksNothingMore() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)   // caches the bar
        zen.tree.focused = zen.urlbar
        zen.tree.set(zen.urlbar) { $0.focused = true }
        zen.tree.resetCalls()
        XCTAssertEqual(r.read(zen.tree, now: 1).observation.pageState, .editingAddress)
        XCTAssertEqual(zen.tree.calls(about: zen.urlbar),
                       [.string(.role, zen.urlbar), .parent(zen.urlbar), .string(.role, zen.urlbar)],
                       "only the prelude's focus walk and focus class touched the bar")
    }

    func testFocusInSidebarReadsTheUnfocusedBar() throws {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .addressBar))
        XCTAssertEqual(r.windows[0].addressBar, zen.urlbar)
        let barCalls = zen.tree.calls(about: zen.urlbar)
        let focusCheck = try XCTUnwrap(barCalls.firstIndex(of: .isFocused(zen.urlbar)))
        let valueRead = try XCTUnwrap(barCalls.firstIndex(of: .string(.value, zen.urlbar)))
        XCTAssertLessThan(focusCheck, valueRead, "focus is checked before the value")
    }

    func testNoFocusReadsTheUnfocusedBar() {
        let zen = BrowserFixtures.zen(focus: .none)
        var r = reader()
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .addressBar))
    }

    func testBarWithUnknownFocusIsNotRead() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        zen.tree.set(zen.urlbar) { $0.focused = nil }
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation, .unknown())
        XCTAssertEqual(valueReads(zen.tree, zen.urlbar), 0, "can't tell whether it's focused: don't read it")
    }

    func testFocusedFlagOnTheBarWinsOverAnOtherFocusClass() {
        // AXFocusedUIElement lags (sidebar), but the bar itself says it's focused.
        let zen = BrowserFixtures.zen(focus: .sidebar)
        zen.tree.set(zen.urlbar) { $0.focused = true }
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.pageState, .editingAddress)
        XCTAssertEqual(valueReads(zen.tree, zen.urlbar), 0)
    }

    // MARK: Compact mode

    func testCompactModeWithoutABarUsesTheWalkElseKeepsTheSite() {
        let zen = BrowserFixtures.zen(focus: .page)
        hideBar(zen)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example, "focus in page: the walk still works")

        zen.tree.focused = zen.sidebarTab
        zen.tree.resetCalls()
        let o = r.read(zen.tree, now: 1).observation
        XCTAssertEqual(o, .unknown(kept: example), "no bar: unknown, the last site kept")
        XCTAssertGreaterThan(zen.tree.childrenCalls, 0, "one scan looked for the bar")
        XCTAssertNil(r.windows[0].addressBar)

        zen.tree.resetCalls()
        XCTAssertEqual(r.read(zen.tree, now: 1 + seconds).observation, .unknown(kept: example))
        XCTAssertEqual(zen.tree.childrenCalls, 0, "≤ 1 scan per window per 2 s")

        zen.tree.resetCalls()
        _ = r.read(zen.tree, now: 1 + 2 * seconds)
        XCTAssertGreaterThan(zen.tree.childrenCalls, 0, "the scan may run again after 2 s")
    }

    // MARK: Bar contents

    func testSearchTermsAreUnknownNotNoSite() {
        for terms in ["todo milk", "weather", "", "   "] {
            let zen = BrowserFixtures.zen(focus: .page)
            var r = reader()
            XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
            zen.tree.focused = zen.sidebarTab
            zen.tree.set(zen.urlbar) { $0.value = terms }
            XCTAssertEqual(r.read(zen.tree, now: 1).observation, .unknown(kept: example), "D10: \(terms)")
            XCTAssertEqual(r.windows[0].lastSite, example)

            let fresh = BrowserFixtures.zen(focus: .sidebar, urlbarValue: terms)
            var f = reader()
            XCTAssertEqual(f.read(fresh.tree, now: 0).observation, .unknown(), "never .notWebPage: \(terms)")
        }
    }

    func testSchemeLessAndFullBarValues() {
        let cases: [(String, SiteAddress)] = [
            ("example.co.il/news", SiteAddress(host: "example.co.il", registrableDomain: "example.co.il", isWebPage: true)),
            ("https://docs.example.org/a?b=c", SiteAddress(host: "docs.example.org", registrableDomain: "example.org",
                                                           isWebPage: true)),
        ]
        for (value, expected) in cases {
            let zen = BrowserFixtures.zen(focus: .sidebar, urlbarValue: value)
            var r = reader()
            XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, expected, value)
        }
    }

    func testAboutPagesAreNotWebPages() {
        let page = BrowserFixtures.zen(focus: .page, pageURL: "about:newtab")
        var r = reader()
        XCTAssertEqual(r.read(page.tree, now: 0).observation,
                       BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL))

        let bar = BrowserFixtures.zen(focus: .page, urlbarValue: "about:preferences")
        var b = reader()
        XCTAssertEqual(b.read(bar.tree, now: 0).observation.site, example)
        bar.tree.focused = bar.sidebarTab
        XCTAssertEqual(b.read(bar.tree, now: 1).observation,
                       BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .addressBar))
        XCTAssertNil(b.windows[0].lastSite, "a not-web page clears the kept site")
    }

    func testWebAreaWithoutAURLFallsBackToTheBar() {
        let zen = BrowserFixtures.zen(focus: .page, urlbarValue: "example.net/x")
        zen.tree.set(zen.webArea) { $0.url = nil }   // still loading
        var r = reader()
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o.site, SiteAddress(host: "example.net", registrableDomain: "example.net", isWebPage: true))
        XCTAssertEqual(o.via, .addressBar)
    }

    func testBarFoundByDescriptionWhenTheIDIsMissing() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        zen.tree.set(zen.urlbar) { $0.domIdentifier = nil }
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
        XCTAssertEqual(r.windows[0].addressBar, zen.urlbar)
    }

    func testIDMatchBeatsAnEarlierDescriptionMatch() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        // A "Search tabs" field closer to the window than the urlbar.
        let other = zen.tree.add("AXTextField", under: zen.window, description: "Search tabs", value: "example.org")
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
        XCTAssertEqual(r.windows[0].addressBar, zen.urlbar)
        XCTAssertEqual(valueReads(zen.tree, other), 0)
    }

    // MARK: Stale bar

    func testStaleCachedBarIsDroppedAndFoundAgainInTheSameRead() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)

        // Zen rebuilt the toolbar: the old element is gone, a new urlbar sits in its place.
        let group = zen.tree.nodes[zen.urlbar]!.parent!
        hideBar(zen)
        zen.tree.errors[zen.urlbar] = .invalidElement
        let fresh = zen.tree.add("AXComboBox", under: group, domIdentifier: "urlbar-input", value: "example.org/x",
                                 focused: false)
        let o = r.read(zen.tree, now: 1).observation   // within 2 s of the first scan: the drop allows one rescan
        XCTAssertEqual(o, BrowserObservation(site: SiteAddress(host: "example.org", registrableDomain: "example.org",
                                                               isWebPage: true),
                                             pageState: .page, isPrivate: nil, via: .addressBar))
        XCTAssertEqual(r.windows[0].addressBar, fresh)
    }

    func testStaleCachedBarWithNoReplacementKeepsTheSite() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
        hideBar(zen)
        zen.tree.errors[zen.urlbar] = .invalidElement
        XCTAssertEqual(r.read(zen.tree, now: 1).observation, .unknown(kept: example))
        XCTAssertNil(r.windows[0].addressBar)
        zen.tree.resetCalls()
        _ = r.read(zen.tree, now: 2)
        XCTAssertEqual(zen.tree.childrenCalls, 0, "only one rescan; then the 2 s limit holds")
    }

    // MARK: Timeouts

    func testATimeoutAnywhereStopsTheReadAndKeepsTheSite() {
        // Count the calls of a cold sidebar read (scan + bar), then hang the browser at each one of them.
        let probe = BrowserFixtures.zen(focus: .sidebar)
        var p = reader()
        _ = p.read(probe.tree, now: 0)
        let total = probe.tree.calls.count

        for hang in 0..<total {
            let zen = BrowserFixtures.zen(focus: .page)
            var r = reader()
            XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
            zen.tree.focused = zen.sidebarTab
            zen.tree.resetCalls()
            zen.tree.hangAfterCalls = hang
            let o = r.read(zen.tree, now: 1).observation
            XCTAssertEqual(o.pageState, .unknown, "hang at \(hang)")
            XCTAssertEqual(o.via, .kept)
            // The first two calls happen before a window is known: nothing to keep yet.
            XCTAssertEqual(o.site, hang < 2 ? nil : example, "hang at \(hang)")
            XCTAssertEqual(zen.tree.calls.count, hang + 1, "nothing asked after the first timeout (hang at \(hang))")
        }
    }

    func testTimeoutOnTheCachedBarValue() {
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
        zen.tree.errors[zen.urlbar] = .timedOut
        zen.tree.resetCalls()
        XCTAssertEqual(r.read(zen.tree, now: 1).observation, .unknown(kept: example))
        XCTAssertEqual(zen.tree.calls.last, .isFocused(zen.urlbar), "the latch stopped the read at the bar")
        XCTAssertEqual(r.windows[0].addressBar, zen.urlbar, "a timeout isn't a stale handle: the bar stays cached")
    }

    // MARK: Walk bound

    /// A Gecko page whose web area (unlisted, like Zen's) is `depth` parents above the focused element.
    private func deepPage(depth: Int, focusRole: String = "AXLink") -> (FakeAXTree, Int) {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        let webArea = t.add("AXWebArea", under: window, listed: false, url: "https://www.example.com/deep")
        var parent = webArea
        for _ in 0..<(depth - 1) { parent = t.add("AXGroup", under: parent) }
        let leaf = t.add(focusRole, under: parent)
        t.main = window
        t.focused = leaf
        return (t, leaf)
    }

    func testWalkGoesBeyondThePreludeUpToThirtyParents() {
        for depth in [17, 25, 30] {
            let (t, _) = deepPage(depth: depth)
            var r = reader()
            XCTAssertEqual(r.read(t, now: 0).observation,
                           BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL), "\(depth)")
        }
    }

    func testWalkStopsAfterThirtyParents() {
        let (t, _) = deepPage(depth: 31)
        var r = reader()
        let o = r.read(t, now: 0).observation
        XCTAssertEqual(o, .unknown(), "31 parents up: not found, and this tree has no bar")
        XCTAssertFalse(t.calls.contains { if case .url = $0 { true } else { false } })
        let parents = t.calls.filter { if case .parent = $0 { true } else { false } }.count
        // Prelude: 17 parents; the strategy re-walks 17 and goes on 14 more (steps 17…30).
        XCTAssertEqual(parents, 17 + 31)
    }

    func testDeepTextFieldInThePageIsNotTheAddressBar() {
        // The prelude calls a text field 20 levels into a page "editing"; the longer walk finds it's in the page.
        let (t, _) = deepPage(depth: 20, focusRole: AXRoleName.textArea)
        var r = reader()
        XCTAssertEqual(r.read(t, now: 0).observation,
                       BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL))
    }

    func testFindBarFocusIsEditingWithoutReadingTheBar() {
        let zen = BrowserFixtures.zen(focus: .page)
        let find = zen.tree.add("AXTextField", under: zen.window, description: "Find in page", focused: true)
        var r = reader()
        XCTAssertEqual(r.read(zen.tree, now: 0).observation.site, example)
        zen.tree.focused = find
        zen.tree.resetCalls()
        XCTAssertEqual(r.read(zen.tree, now: 1).observation,
                       BrowserObservation(site: example, pageState: .editingAddress, isPrivate: nil, via: .kept))
        XCTAssertEqual(zen.tree.calls(about: zen.urlbar), [])
        XCTAssertEqual(zen.tree.childrenCalls, 0)
    }

    // MARK: Call budget (B13)

    func testCallBudgetPerRead() {
        // Cold: focus in the sidebar, one scan to find the bar, then its focus and value.
        let zen = BrowserFixtures.zen(focus: .sidebar)
        var r = reader()
        _ = r.read(zen.tree, now: 0)
        let cold = zen.tree.calls.count
        let scanned = zen.tree.calls.filter { if case .string(.role, _) = $0 { true } else { false } }.count
        XCTAssertLessThanOrEqual(scanned, 25, "the scan stops at the bar (the Zen fixture has 19 nodes)")
        XCTAssertEqual(cold, 43, "measured: 2 app + 9 prelude focus walk + 4 walk extension + 26 scan + 2 bar")

        // Warm: the cached bar, no scan.
        zen.tree.resetCalls()
        _ = r.read(zen.tree, now: 1)
        XCTAssertEqual(zen.tree.childrenCalls, 0)
        XCTAssertEqual(zen.tree.calls.count, 17, "measured: 2 app + 9 prelude focus walk + 4 walk extension + 2 bar")

        // Focus in page: 4 calls, whatever the bar.
        zen.tree.focused = zen.webArea
        zen.tree.resetCalls()
        _ = r.read(zen.tree, now: 2)
        XCTAssertEqual(zen.tree.calls.count, 4)
    }
}
