// P3-7: The Automation fallback inside `BrowserAddressReader` (001 §14.7, D9) on fake AX trees, with the recording
// fake sender (no real Apple Event is ever sent from tests).

import XCTest

final class AppleEventReaderTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000
    private let second: UInt64 = 1_000_000_000
    private var siteReader: SiteReader!
    private var sender: FakeAppleEventSender!
    private var gate: AppleEventSendGate!
    private var fallback: AppleEventFallback!

    override func setUpWithError() throws {
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
        sender = FakeAppleEventSender()
        gate = AppleEventSendGate()
        gate.allow(pid: 7)
        fallback = AppleEventFallback(sender: sender, gate: gate)
    }

    private func request(_ engine: BrowserEngine = .chromium, dialect: AppleScriptDialect?,
                         ignorePrivate: Bool = false) -> BrowserWatchRequest {
        BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: ignorePrivate,
                            appleScript: dialect)
    }

    private func reader(_ engine: BrowserEngine = .chromium, dialect: AppleScriptDialect?,
                        ignorePrivate: Bool = false, withSession: Bool = true) -> BrowserAddressReader<FakeAXTree> {
        var r = BrowserAddressReader<FakeAXTree>(request: request(engine, dialect: dialect, ignorePrivate: ignorePrivate),
                                                 siteReader: siteReader)
        if withSession, let dialect { r.appleEvents = AppleEventSession(pid: 7, dialect: dialect, fallback: fallback) }
        return r
    }

    /// A Chromium window whose AX tree shows no web area (a cold Chrome): the AX read gives `.unknown` with a window.
    private func coldChromium() -> (tree: FakeAXTree, window: Int) {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app)
        let group = t.add("AXGroup", under: window)
        let button = t.add("AXButton", under: group)
        t.main = window
        t.focusedWin = window
        t.focused = button
        return (t, window)
    }

    // MARK: - Address (rule 1)

    func testUnknownWithAWindowAsksForTheAddress() {
        var r = reader(dialect: .safari)
        sender.addressReplies = [.text("https://www.ynet.co.il/home")]
        let (o, sawWindow) = r.read(coldChromium().tree, now: t0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o.pageState, .page)
        XCTAssertEqual(o.via, .appleEvent)
        XCTAssertEqual(o.site?.registrableDomain, "ynet.co.il")
        XCTAssertEqual(sender.addressSends, 1)
        XCTAssertEqual(sender.sent.first?.pid, 7)
    }

    func testANonWebAddressGivesNotWebPage() {
        var r = reader(dialect: .safari)
        sender.addressReplies = [.text("chrome://newtab/")]
        let (o, _) = r.read(coldChromium().tree, now: t0)
        XCTAssertEqual(o.pageState, .notWebPage)
        XCTAssertNil(o.site)
        XCTAssertEqual(o.via, .appleEvent)
    }

    func testAFailedSendStaysUnknown() {
        var r = reader(dialect: .safari)
        sender.addressReplies = [.failed(.timedOut)]
        let (o, _) = r.read(coldChromium().tree, now: t0)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertEqual(o.via, .kept)
    }

    func testNoSessionMeansNoAppleEvent() {
        // Not opted in, or not granted: SitePolicy gives no dialect and the engine sets no session.
        var r = reader(dialect: nil)
        let (o, _) = r.read(coldChromium().tree, now: t0)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testAPageReadByAXSendsNoAddressEvent() {
        var r = reader(dialect: .arc)
        sender.privateReplies = [.flag(false)]
        let (o, _) = r.read(BrowserFixtures.arc().tree, now: t0)
        XCTAssertEqual(o.pageState, .page)
        XCTAssertEqual(o.via, .axURL)
        XCTAssertEqual(sender.addressSends, 0)
        XCTAssertEqual(sender.privateSends, 1, "rule 2 only")
    }

    func testANonWebPageReadByAXSendsNoAddressEvent() {
        var r = reader(dialect: .safari)
        let (o, _) = r.read(BrowserFixtures.chrome(pageURL: "chrome://newtab/").tree, now: t0)
        XCTAssertEqual(o.pageState, .notWebPage)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testEditingTheAddressBarSendsNothing() {
        var r = reader(dialect: .safari)
        let (o, _) = r.read(BrowserFixtures.chrome(pageURL: "https://example.com/", omniboxFocused: true).tree, now: t0)
        XCTAssertEqual(o.pageState, .editingAddress)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testNoWindowSendsNothing() {
        var r = reader(dialect: .chromium)
        let t = FakeAXTree()
        t.add("AXApplication")
        let (o, sawWindow) = r.read(t, now: t0)
        XCTAssertFalse(sawWindow)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testAnAXTimeoutWithAWindowAsksForTheAddress() {
        var r = reader(dialect: .safari)
        let cold = coldChromium()
        cold.tree.hangAfterCalls = 3   // focused element, main window, then the walk times out
        sender.addressReplies = [.text("https://example.org/")]
        let (o, sawWindow) = r.read(cold.tree, now: t0)
        XCTAssertTrue(sawWindow)
        XCTAssertEqual(o.pageState, .page)
        // P3-25 (Coordinator decision): the bar's focus was unknown: applied, never learned.
        XCTAssertEqual(o.via, .appleEventAfterTimeout)
        XCTAssertTrue(o.siteNotLearnable)
    }

    func testAnAppleEventAfterAGoodAXReadIsStillLearnable() {
        // P3-25: only the timeout path is marked.
        XCTAssertFalse(BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .appleEvent)
            .siteNotLearnable)
        let o = BrowserObservation(site: nil, pageState: .page, isPrivate: nil, via: .axURL)
        XCTAssertEqual(o.afterAXTimeout(), o, "only an Apple Event answer is re-marked")
    }

    func testAClosedGateSendsNothing() {
        gate.allow(pid: nil)   // main detached: another app in front, or Kytkin paused/off
        var r = reader(dialect: .safari)
        let (o, _) = r.read(coldChromium().tree, now: t0)
        XCTAssertEqual(o.pageState, .unknown)
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertNil(r.takeAppleEventRetry(), "no retry: nothing is allowed")
    }

    // MARK: - Rate limit

    func testAHeldBackSendKeepsTheLastAppleEventStateAndAsksForARetry() {
        var r = reader(dialect: .safari)
        let tree = coldChromium().tree
        sender.addressReplies = [.text("https://example.com/a"), .text("https://example.net/")]
        _ = r.read(tree, now: t0)
        XCTAssertNil(r.takeAppleEventRetry())

        let (held, _) = r.read(tree, now: t0 + 300_000_000)
        XCTAssertEqual(sender.addressSends, 1, "≤ 1 per second")
        XCTAssertEqual(held.pageState, .page, "no flip to .unknown and back (D5)")
        XCTAssertEqual(held.site?.registrableDomain, "example.com")
        XCTAssertEqual(r.takeAppleEventRetry(), t0 + second)
        XCTAssertNil(r.takeAppleEventRetry(), "taken once")

        let (later, _) = r.read(tree, now: t0 + second)
        XCTAssertEqual(sender.addressSends, 2)
        XCTAssertEqual(later.site?.registrableDomain, "example.net")
    }

    func testAnAXAnswerClearsTheKeptAppleEventState() {
        var r = reader(dialect: .safari)
        let chrome = BrowserFixtures.chrome(pageURL: "https://example.com/")
        // First read: hide the web areas so AX can't tell.
        chrome.tree.errors = [chrome.bigWebArea: .invalidElement, chrome.smallWebArea: .invalidElement]
        sender.addressReplies = [.text("https://example.com/")]
        _ = r.read(chrome.tree, now: t0)
        XCTAssertEqual(r.windows.first?.appleEventState, .page)
        chrome.tree.errors = [:]
        let (o, _) = r.read(chrome.tree, now: t0 + 2 * second)
        XCTAssertEqual(o.via, .axURL)
        XCTAssertNil(r.windows.first?.appleEventState)
    }

    // MARK: - Private flag (rule 2)

    func testChromiumPrivateFlagAskedOncePerWindow() {
        var r = reader(dialect: .chromium)
        sender.privateReplies = [.text("incognito")]
        let tree = BrowserFixtures.chrome(pageURL: "https://example.com/").tree
        let (first, _) = r.read(tree, now: t0)
        XCTAssertEqual(first.isPrivate, true)
        r.noteTrigger(.titleChanged)   // re-checks the AX probe, not the Apple Event
        let (second, _) = r.read(tree, now: t0 + 3 * self.second)
        XCTAssertEqual(second.isPrivate, true)
        XCTAssertEqual(sender.privateSends, 1)
    }

    func testAPrivateFlagThatCantTellIsAlsoCached() {
        var r = reader(dialect: .chromium)
        sender.privateReplies = [.failed(.timedOut)]
        let tree = BrowserFixtures.chrome(pageURL: "https://example.com/").tree
        XCTAssertNil(r.read(tree, now: t0).observation.isPrivate)
        XCTAssertNil(r.read(tree, now: t0 + 3 * second).observation.isPrivate)
        XCTAssertEqual(sender.privateSends, 1)
    }

    func testAnIgnoredPrivateWindowIsNeverAskedForItsAddress() {
        // D12: the Apple Event says private and the user ignores private windows → no address read, by AX or AE.
        var r = reader(dialect: .chromium, ignorePrivate: true)
        sender.privateReplies = [.text("incognito")]
        let tree = coldChromium().tree
        let (o, _) = r.read(tree, now: t0)
        XCTAssertEqual(o.isPrivate, true)
        XCTAssertNil(o.site)
        let (again, _) = r.read(tree, now: t0 + 3 * second)
        XCTAssertNil(again.site)
        XCTAssertEqual(sender.addressSends, 0)
        XCTAssertNil(r.takeAppleEventRetry())
    }

    func testPrivateFirstThenTheAddressOnTheRetry() {
        var r = reader(dialect: .chromium)
        sender.privateReplies = [.text("normal")]
        sender.addressReplies = [.text("https://example.com/")]
        let tree = coldChromium().tree
        let (first, _) = r.read(tree, now: t0)
        XCTAssertEqual(first.pageState, .unknown)
        XCTAssertEqual(first.isPrivate, false)
        XCTAssertEqual(r.takeAppleEventRetry(), t0 + second)
        let (second, _) = r.read(tree, now: t0 + second)
        XCTAssertEqual(second.pageState, .page)
        XCTAssertEqual(second.isPrivate, false)
        XCTAssertEqual(sender.sent.count, 2)
    }

    func testAnAXPrivateProbeAnswerMeansNoAppleEvent() {
        var r = BrowserAddressReader<FakeAXTree>(
            request: request(dialect: .chromium), siteReader: siteReader,
            strategy: BrowserAddressReader<FakeAXTree>.defaultStrategy(for: .chromium),
            privateProbe: { (_: LatchedAXTree<FakeAXTree>, _: Int) throws(AXReadError) -> Bool? in false })
        r.appleEvents = AppleEventSession(pid: 7, dialect: .chromium, fallback: fallback)
        let (o, _) = r.read(BrowserFixtures.chrome(pageURL: "https://example.com/").tree, now: t0)
        XCTAssertEqual(o.isPrivate, false)
        XCTAssertTrue(sender.sent.isEmpty)
    }
}
