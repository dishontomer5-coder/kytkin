// P3-6: The common read frame (001 §14.3.3 prelude): window choice, focus class, the per-window cache and kept
// site, the private-window gate (D12), the timeout latch and invalid handles. Engine strategies are P3-11/P3-13;
// here a small test strategy stands in for them.

import XCTest

/// Test-only strategy: in page → the focus web area's AXURL; else the window's cached web area; editing → nothing.
/// Counts its calls. A scripted outcome overrides all that.
final class ProbeStrategy: BrowserReadStrategy {
    typealias Tree = LatchedAXTree<FakeAXTree>
    var calls = 0
    var scripted: BrowserReadOutcome?
    /// Called inside `read`, e.g. to retry after an error and check the latch.
    var extra: ((Tree) -> Void)?
    /// Called inside `read` with the window's cache entry.
    var touchWindow: ((inout BrowserWindowState<Int>) -> Void)?

    func read(_ tree: Tree, prelude: BrowserReadPrelude<Int>, window: inout BrowserWindowState<Int>,
              siteReader: SiteReader, now: UInt64) throws(AXReadError) -> BrowserReadOutcome {
        calls += 1
        extra?(tree)
        touchWindow?(&window)
        if let scripted { return scripted }
        if prelude.focusClass == .editing { return .editingKept }
        guard let webArea = prelude.webAreaFromFocus ?? window.webArea else { return .unknown }
        window.webArea = webArea
        guard let url = try tree.url(of: webArea) else { return .unknown }
        return BrowserReadOutcome(read: siteReader.read(url, from: .axURL), via: .axURL)
    }
}

final class BrowserAddressReaderTests: XCTestCase {
    private var siteReader: SiteReader!
    private var strategy: ProbeStrategy!
    private var probeCalls = 0
    private var probeAnswer: Bool?

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
        strategy = ProbeStrategy()
        probeCalls = 0
        probeAnswer = nil
    }

    private func request(_ engine: BrowserEngine = .chromium, alwaysPrivate: Bool = false,
                         ignorePrivate: Bool = false) -> BrowserWatchRequest {
        BrowserWatchRequest(engine: engine, alwaysPrivate: alwaysPrivate, ignorePrivateWindows: ignorePrivate,
                            appleScript: nil)
    }

    private func reader(_ request: BrowserWatchRequest? = nil) -> BrowserAddressReader<FakeAXTree> {
        BrowserAddressReader(request: request ?? self.request(), siteReader: siteReader, strategy: strategy,
                             privateProbe: { [unowned self] (_: LatchedAXTree<FakeAXTree>, _: Int) throws(AXReadError) -> Bool? in
                                 probeCalls += 1
                                 return probeAnswer
                             })
    }

    private func site(_ host: String, _ domain: String?) -> SiteAddress {
        SiteAddress(host: host, registrableDomain: domain, isWebPage: true)
    }

    // MARK: Window and focus

    func testNoWindowIsUnknownWithoutAWindow() {
        let t = FakeAXTree()
        var r = reader()
        let (o, sawWindow) = r.read(t, now: 0)
        XCTAssertFalse(sawWindow)
        XCTAssertEqual(o, .unknown())
        XCTAssertEqual(strategy.calls, 0)
    }

    func testChromePopupFocusedWindowIsNotUsed() {
        let chrome = BrowserFixtures.chrome(reportsMainWindow: false)
        var r = reader()
        XCTAssertFalse(r.read(chrome.tree, now: 0).sawWindow)
    }

    func testStandardFocusedWindowIsUsedWhenNoMainWindow() {
        let arc = BrowserFixtures.arc()
        arc.tree.main = nil
        var r = reader()
        let (o, sawWindow) = r.read(arc.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o.site, site("example.org", "example.org"))
    }

    func testArcFocusInsidePageReadsItsWebArea() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        let (o, sawWindow) = r.read(arc.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, BrowserObservation(site: site("example.org", "example.org"), pageState: .page,
                                             isPrivate: nil, via: .axURL))
    }

    func testZenPageReadByUpWalk() {
        let zen = BrowserFixtures.zen()
        var r = reader(request(.gecko))
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o.site, site("www.example.com", "example.com"))
        XCTAssertEqual(o.pageState, .page)
    }

    func testFocusWalkStopsAfterSixteenParents() throws {
        let t = FakeAXTree()
        let window = t.add("AXWindow", subrole: "AXStandardWindow")
        let webArea = t.add("AXWebArea", under: window, url: "https://example.com/")
        var parent = webArea
        for _ in 0..<16 { parent = t.add("AXGroup", under: parent) }
        let atLimit = parent                           // web area is 16 parents up
        let beyond = t.add("AXGroup", under: parent)   // 17 parents up
        typealias R = BrowserAddressReader<FakeAXTree>
        XCTAssertEqual(try R.classifyFocus(atLimit, tree: t).0, .inPage)
        XCTAssertEqual(try R.classifyFocus(beyond, tree: t).0, .other)
    }

    func testFocusedTextFieldOutsidePageIsEditing() {
        let chrome = BrowserFixtures.chrome(omniboxFocused: true)
        var r = reader()
        let o = r.read(chrome.tree, now: 0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertNil(o.site)
        XCTAssertTrue(chrome.tree.calls(about: chrome.omnibox).allSatisfy { $0 != .string(.value, chrome.omnibox) })
    }

    // MARK: Kept site

    func testUnreadableKeepsTheWindowsLastSiteAndNotWebClearsIt() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        strategy.scripted = BrowserReadOutcome(read: .unreadable, via: .addressBar)
        XCTAssertEqual(r.read(arc.tree, now: 1).observation,
                       BrowserObservation(site: site("example.org", "example.org"), pageState: .unknown,
                                          isPrivate: nil, via: .kept))
        strategy.scripted = .unknown
        XCTAssertEqual(r.read(arc.tree, now: 2).observation.site, site("example.org", "example.org"))
        strategy.scripted = .editingKept
        XCTAssertEqual(r.read(arc.tree, now: 3).observation,
                       BrowserObservation(site: site("example.org", "example.org"), pageState: .editingAddress,
                                          isPrivate: nil, via: .kept))
        strategy.scripted = BrowserReadOutcome(read: .notWebPage, via: .axURL)
        XCTAssertEqual(r.read(arc.tree, now: 4).observation,
                       BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL))
        strategy.scripted = .unknown
        XCTAssertEqual(r.read(arc.tree, now: 5).observation, .unknown())
    }

    func testEditingWithAFreshSiteReportsItAsEditing() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        strategy.scripted = BrowserReadOutcome(read: .site(site("example.org", "example.org")), via: .axURL, editing: true)
        let o = r.read(arc.tree, now: 0).observation
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertEqual(o.site, site("example.org", "example.org"))
        strategy.scripted = .unknown
        XCTAssertEqual(r.read(arc.tree, now: 1).observation.site, site("example.org", "example.org"))
    }

    func testKeptSitesArePerWindow() {
        let t = FakeAXTree()
        let w1 = t.add("AXWindow", subrole: "AXStandardWindow")
        let a1 = t.add("AXWebArea", under: w1, url: "https://example.com/")
        let w2 = t.add("AXWindow", subrole: "AXStandardWindow")
        let a2 = t.add("AXWebArea", under: w2, url: "https://example.org/")
        var r = reader()
        t.main = w1; t.focused = a1
        XCTAssertEqual(r.read(t, now: 0).observation.site?.host, "example.com")
        t.main = w2; t.focused = a2
        XCTAssertEqual(r.read(t, now: 1).observation.site?.host, "example.org")
        strategy.scripted = .unknown
        t.main = w1
        XCTAssertEqual(r.read(t, now: 2).observation.site?.host, "example.com")
        let w3 = t.add("AXWindow", subrole: "AXStandardWindow")
        t.main = w3
        XCTAssertNil(r.read(t, now: 3).observation.site, "a new window starts with no kept site")
    }

    func testWindowCacheKeepsAtMostEightWindows() {
        let t = FakeAXTree()
        var r = reader()
        strategy.scripted = .unknown
        var windows: [Int] = []
        for i in 0..<10 {
            let w = t.add("AXWindow", subrole: "AXStandardWindow")
            windows.append(w)
            t.main = w
            _ = r.read(t, now: UInt64(i))
        }
        XCTAssertEqual(r.windows.count, BrowserReadLimits.cachedWindows)
        XCTAssertEqual(r.windows.first?.window, windows.last, "most recent first")
        XCTAssertFalse(r.windows.contains { $0.window == windows[0] })
    }

    // MARK: Private windows (D12)

    func testPrivateWindowIgnoredSkipsTheAddressRead() {
        let arc = BrowserFixtures.arc()
        probeAnswer = true
        var r = reader(request(ignorePrivate: true))
        let (o, sawWindow) = r.read(arc.tree, now: 0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, BrowserObservation(site: nil, pageState: .unknown, isPrivate: true, via: .kept))
        XCTAssertEqual(strategy.calls, 0)
        XCTAssertFalse(arc.tree.calls.contains { if case .url = $0 { true } else { false } }, "no AXURL read")
    }

    func testPrivateWindowNotIgnoredIsReadAndFlagged() {
        let arc = BrowserFixtures.arc()
        probeAnswer = true
        var r = reader()
        let o = r.read(arc.tree, now: 0).observation
        XCTAssertEqual(o.isPrivate, true)
        XCTAssertEqual(o.pageState, .page)
    }

    func testUnknownPrivateFlagCountsAsNotPrivate() {
        let arc = BrowserFixtures.arc()
        var r = reader(request(ignorePrivate: true))
        let o = r.read(arc.tree, now: 0).observation
        XCTAssertNil(o.isPrivate)
        XCTAssertEqual(o.pageState, .page)
    }

    func testTorIsAlwaysPrivateWithoutAProbe() {
        let zen = BrowserFixtures.zen()
        var r = reader(request(.gecko, alwaysPrivate: true, ignorePrivate: true))
        let o = r.read(zen.tree, now: 0).observation
        XCTAssertEqual(o.isPrivate, true)
        XCTAssertNil(o.site)
        XCTAssertEqual(probeCalls, 0)
        XCTAssertEqual(strategy.calls, 0)
    }

    func testPrivateFlagIsProbedOncePerWindowUntilAWindowOrTitleChange() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        _ = r.read(arc.tree, now: 1)
        XCTAssertEqual(probeCalls, 1)
        r.noteTrigger(.focusedElementChanged)
        r.noteTrigger(.loadComplete)
        _ = r.read(arc.tree, now: 2)
        XCTAssertEqual(probeCalls, 1)
        probeAnswer = true
        r.noteTrigger(.titleChanged)
        XCTAssertEqual(r.read(arc.tree, now: 3).observation.isPrivate, true)
        XCTAssertEqual(probeCalls, 2)
        r.noteTrigger(.mainWindowChanged)
        _ = r.read(arc.tree, now: 4)
        XCTAssertEqual(probeCalls, 3)
    }

    // MARK: Errors

    func testTimeoutStopsTheReadAndKeepsTheSite() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        _ = r.read(arc.tree, now: 0)
        arc.tree.errors[arc.webArea] = .timedOut
        let (o, sawWindow) = r.read(arc.tree, now: 1)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o, .unknown(kept: site("example.org", "example.org")))
    }

    func testLatchFailsEveryCallAfterTheFirstTimeoutWithoutAskingTheBrowser() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        var secondError: AXReadError?
        var callsBefore = 0
        strategy.scripted = .unknown
        strategy.extra = { tree in
            do { _ = try tree.url(of: arc.webArea) } catch {}        // times out, trips the latch
            callsBefore = arc.tree.calls.count
            do { _ = try tree.children(of: arc.window) } catch { secondError = error as? AXReadError }
        }
        arc.tree.focused = nil   // so the prelude's focus walk doesn't touch the web area first
        arc.tree.errors[arc.webArea] = .timedOut
        _ = r.read(arc.tree, now: 0)
        XCTAssertEqual(secondError, .timedOut)
        XCTAssertEqual(arc.tree.calls.count, callsBefore, "the second call never reached the browser")
    }

    func testEachReadStartsWithAFreshLatch() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        arc.tree.appError = .timedOut
        XCTAssertFalse(r.read(arc.tree, now: 0).sawWindow)
        arc.tree.appError = nil
        XCTAssertEqual(r.read(arc.tree, now: 1).observation.pageState, .page)
    }

    func testHungBrowserMidReadIsUnknown() {
        let zen = BrowserFixtures.zen()
        var r = reader(request(.gecko))
        zen.tree.hangAfterCalls = 3
        let (o, _) = r.read(zen.tree, now: 0)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertEqual(zen.tree.calls.count, 4, "stops at the first timeout")
    }

    func testInvalidElementDropsCachedHandlesAndAllowsARescan() {
        let arc = BrowserFixtures.arc()
        var r = reader()
        strategy.touchWindow = { $0.lastFullScanAt = 5 }
        _ = r.read(arc.tree, now: 0)
        strategy.touchWindow = nil
        XCTAssertEqual(r.windows.first?.webArea, arc.webArea)
        XCTAssertEqual(r.windows.first?.lastFullScanAt, 5)
        arc.tree.focused = nil
        arc.tree.errors[arc.webArea] = .invalidElement
        let o = r.read(arc.tree, now: 6).observation
        XCTAssertEqual(o, .unknown(kept: site("example.org", "example.org")))
        XCTAssertNil(r.windows.first?.webArea)
        XCTAssertNil(r.windows.first?.lastFullScanAt)
        XCTAssertTrue(r.windows.first?.mayFullScan(now: 6) ?? false)
    }

    func testFullScanLimitIsOncePerTwoSeconds() {
        var state = BrowserWindowState(window: 1)
        XCTAssertTrue(state.mayFullScan(now: 0))
        state.lastFullScanAt = 1_000
        XCTAssertFalse(state.mayFullScan(now: 1_000 + BrowserReadLimits.fullScanIntervalNanos - 1))
        XCTAssertTrue(state.mayFullScan(now: 1_000 + BrowserReadLimits.fullScanIntervalNanos))
    }

    // MARK: Default strategies (until P3-11/P3-13)

    func testEveryEngineHasAStrategyThatReadsNothingYet() {
        for engine in [BrowserEngine.chromium, .gecko, .webkit, .unknown] {
            let arc = BrowserFixtures.arc()
            var r = BrowserAddressReader<FakeAXTree>(request: request(engine), siteReader: siteReader)
            let (o, sawWindow) = r.read(arc.tree, now: 0)
            XCTAssertTrue(sawWindow)
            XCTAssertEqual(o, .unknown(), "\(engine)")
            XCTAssertFalse(arc.tree.calls.contains { if case .url = $0 { true } else { false } })
            let zen = BrowserFixtures.zen(focus: .urlbar)
            XCTAssertEqual(r.read(zen.tree, now: 1).observation.pageState, .editingAddress)
            XCTAssertFalse(zen.tree.calls.contains(.string(.value, zen.urlbar)), "a focused bar is never read (D2)")
            // QA: the Chromium omnibox is never read, focused (D2) or not (D16).
            for focused in [true, false] {
                let chrome = BrowserFixtures.chrome(omniboxFocused: focused)
                var c = BrowserAddressReader<FakeAXTree>(request: request(engine), siteReader: siteReader)
                _ = c.read(chrome.tree, now: 0)
                XCTAssertFalse(chrome.tree.calls.contains(.string(.value, chrome.omnibox)), "\(engine) \(focused)")
            }
        }
    }
}
