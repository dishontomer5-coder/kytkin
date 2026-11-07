// P3-7: The Automation fallback's pure rules (001 §14.7, D9): the object paths per dialect, the failure mapping, the
// 1 s rate limit, the main-owned gate, the per-pid stop after a permission failure, and the reply mapping. Also the
// reader integration on fake trees: an address Apple Event only for `.unknown` with a window, never while editing,
// never for an ignored private window, the private flag once per window, Safari never asked for it. A recording
// fake sender stands in for AppleEventAddressReader (never compiled into tests): nothing here sends a real event.

import XCTest

/// Records every send and answers from a script (FIFO per query kind; `.failed(.other(0))` when it runs out).
final class FakeAppleEventSender: AppleEventSending {
    struct Sent: Equatable {
        let path: AppleEventObjectPath
        let pid: Int32
        let timeout: Double
    }

    private(set) var sent: [Sent] = []
    var addressReplies: [AppleEventReply] = []
    var privateReplies: [AppleEventReply] = []

    func send(_ path: AppleEventObjectPath, to pid: Int32, timeoutSeconds: Double) -> AppleEventReply {
        sent.append(Sent(path: path, pid: pid, timeout: timeoutSeconds))
        let isAddress = path.property == "URL " || path.property == "pURL"
        if isAddress { return addressReplies.isEmpty ? .failed(.other(0)) : addressReplies.removeFirst() }
        return privateReplies.isEmpty ? .failed(.other(0)) : privateReplies.removeFirst()
    }

    var addressSends: Int { sent.filter { $0.path.property == "URL " || $0.path.property == "pURL" }.count }
    var privateSends: Int { sent.count - addressSends }
}

final class AppleEventFallbackTests: XCTestCase {
    private let t0: UInt64 = 10_000_000_000
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

    // MARK: - Paths and codes

    func testFourCharCodes() {
        XCTAssertEqual(AppleEventObjectPath.code("cwin"), 0x6377_696E)
        XCTAssertEqual(AppleEventObjectPath.code("URL "), 0x5552_4C20)
        XCTAssertEqual(AppleEventObjectPath.code("core"), 0x636F_7265)
    }

    func testPathsPerDialectFromTheScriptingDictionaries() {
        XCTAssertEqual(AppleScriptDialect.chromium.path(for: .activeTabAddress),
                       AppleEventObjectPath(windowClass: "cwin", tabProperty: "acTa", property: "URL "))
        XCTAssertEqual(AppleScriptDialect.chromium.path(for: .frontWindowPrivate),
                       AppleEventObjectPath(windowClass: "cwin", tabProperty: nil, property: "mode"))
        XCTAssertEqual(AppleScriptDialect.arc.path(for: .activeTabAddress),
                       AppleEventObjectPath(windowClass: "WiND", tabProperty: "acTa", property: "URL "))
        XCTAssertEqual(AppleScriptDialect.arc.path(for: .frontWindowPrivate),
                       AppleEventObjectPath(windowClass: "WiND", tabProperty: nil, property: "inco"))
        XCTAssertEqual(AppleScriptDialect.safari.path(for: .activeTabAddress),
                       AppleEventObjectPath(windowClass: "cwin", tabProperty: "cTab", property: "pURL"))
        XCTAssertNil(AppleScriptDialect.safari.path(for: .frontWindowPrivate), "Safari has no private-window property")
        XCTAssertTrue(AppleScriptDialect.chromium.hasPrivateFlag)
        XCTAssertTrue(AppleScriptDialect.arc.hasPrivateFlag)
        XCTAssertFalse(AppleScriptDialect.safari.hasPrivateFlag)
    }

    func testGeckoBrowsersHaveNoDialect() {
        for b in BrowserCatalog.all where b.engine == .gecko {
            XCTAssertNil(b.appleScript, b.bundleID)
        }
    }

    func testFailureMapping() {
        XCTAssertEqual(AppleEventFailure(status: -1743), .notPermitted)
        XCTAssertEqual(AppleEventFailure(status: -1744), .needsConsent)
        XCTAssertEqual(AppleEventFailure(status: -600), .notRunning)
        XCTAssertEqual(AppleEventFailure(status: -1712), .timedOut)
        XCTAssertEqual(AppleEventFailure(status: -1728), .noSuchObject)
        XCTAssertEqual(AppleEventFailure(status: -50), .other(-50))
        XCTAssertTrue(AppleEventFailure.notPermitted.isPermissionProblem)
        XCTAssertTrue(AppleEventFailure.needsConsent.isPermissionProblem)
        XCTAssertFalse(AppleEventFailure.timedOut.isPermissionProblem)
    }

    // MARK: - Rate limit and gate

    func testRateLimiterAllowsOnePerSecond() {
        var r = AppleEventRateLimiter()
        XCTAssertTrue(r.take(now: t0))
        XCTAssertFalse(r.take(now: t0 + 999_999_999))
        XCTAssertEqual(r.nextAllowedAt(now: t0 + 500_000_000), t0 + 1_000_000_000)
        XCTAssertTrue(r.take(now: t0 + 1_000_000_000))
        XCTAssertNil(r.nextAllowedAt(now: t0 + 2_000_000_000))
    }

    func testGateAllowsOnlyThePidMainSet() {
        let g = AppleEventSendGate()
        XCTAssertFalse(g.allows(7), "closed by default")
        g.allow(pid: 7)
        XCTAssertTrue(g.allows(7))
        XCTAssertFalse(g.allows(8))
        g.allow(pid: nil)
        XCTAssertFalse(g.allows(7))
    }

    func testSendUsesTheHalfSecondTimeoutAndThePid() {
        sender.addressReplies = [.text("https://example.com/")]
        let r = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0)
        XCTAssertEqual(r, .answered(.text("https://example.com/")))
        XCTAssertEqual(sender.sent, [.init(path: AppleScriptDialect.chromium.path(for: .activeTabAddress)!, pid: 7,
                                           timeout: 0.5)])
    }

    func testClosedGateMeansNoSendAndNoRetry() {
        gate.allow(pid: nil)
        XCTAssertEqual(fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0), .notSent(retryAt: nil))
        gate.allow(pid: 8)   // another browser is in front now
        XCTAssertEqual(fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0), .notSent(retryAt: nil))
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testSecondSendWithinASecondIsHeldBackWithARetryTime() {
        _ = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0)
        XCTAssertEqual(fallback.send(.frontWindowPrivate, dialect: .chromium, pid: 7, now: t0 + 300_000_000),
                       .notSent(retryAt: t0 + 1_000_000_000))
        XCTAssertEqual(sender.sent.count, 1)
    }

    func testPermissionFailureStopsSendsToThatPidUntilTheNextAttach() {
        sender.addressReplies = [.failed(.notPermitted)]
        _ = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0)
        XCTAssertEqual(fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0 + 5_000_000_000),
                       .notSent(retryAt: nil))
        XCTAssertEqual(sender.sent.count, 1)
        fallback.attached(pid: 7)
        _ = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0 + 6_000_000_000)
        XCTAssertEqual(sender.sent.count, 2)
    }

    func testATimeoutDoesNotStopLaterSends() {
        sender.addressReplies = [.failed(.timedOut)]
        _ = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0)
        _ = fallback.send(.activeTabAddress, dialect: .chromium, pid: 7, now: t0 + 1_000_000_000)
        XCTAssertEqual(sender.sent.count, 2)
    }

    func testSafariIsNeverAskedForThePrivateFlag() {
        let s = AppleEventSession(pid: 7, dialect: .safari, fallback: fallback)
        XCTAssertEqual(s.readPrivateFlag(now: t0), .notSent(retryAt: nil))
        XCTAssertTrue(sender.sent.isEmpty)
    }

    // MARK: - Mapping

    func testAddressReplyGoesThroughSiteReader() {
        XCTAssertEqual(AppleEventFallback.siteRead(from: .text("https://www.ynet.co.il/news"), siteReader: siteReader)
            .site?.registrableDomain, "ynet.co.il")
        XCTAssertEqual(AppleEventFallback.siteRead(from: .text("chrome://newtab/"), siteReader: siteReader), .notWebPage)
        XCTAssertEqual(AppleEventFallback.siteRead(from: .text(""), siteReader: siteReader), .unreadable)
        XCTAssertEqual(AppleEventFallback.siteRead(from: .text("example.com"), siteReader: siteReader), .unreadable,
                       "scheme-less text is accepted only from the Gecko bar")
        XCTAssertEqual(AppleEventFallback.siteRead(from: .failed(.timedOut), siteReader: siteReader), .unreadable)
        XCTAssertEqual(AppleEventFallback.siteRead(from: .flag(true), siteReader: siteReader), .unreadable)
    }

    func testPrivateFlagMapping() {
        XCTAssertEqual(AppleEventFallback.privateFlag(from: .text("incognito"), dialect: .chromium), true)
        XCTAssertEqual(AppleEventFallback.privateFlag(from: .text("normal"), dialect: .chromium), false)
        XCTAssertNil(AppleEventFallback.privateFlag(from: .text("other"), dialect: .chromium))
        XCTAssertEqual(AppleEventFallback.privateFlag(from: .flag(true), dialect: .arc), true)
        XCTAssertEqual(AppleEventFallback.privateFlag(from: .flag(false), dialect: .arc), false)
        XCTAssertNil(AppleEventFallback.privateFlag(from: .text("incognito"), dialect: .arc))
        XCTAssertNil(AppleEventFallback.privateFlag(from: .failed(.timedOut), dialect: .chromium))
        XCTAssertNil(AppleEventFallback.privateFlag(from: .flag(true), dialect: .safari))
    }

    func testWantsAddressOnlyForUnknownWithAWindow() {
        XCTAssertTrue(AppleEventFallback.wantsAddress(pageState: .unknown, sawWindow: true))
        XCTAssertFalse(AppleEventFallback.wantsAddress(pageState: .unknown, sawWindow: false))
        XCTAssertFalse(AppleEventFallback.wantsAddress(pageState: .page, sawWindow: true))
        XCTAssertFalse(AppleEventFallback.wantsAddress(pageState: .notWebPage, sawWindow: true))
        XCTAssertFalse(AppleEventFallback.wantsAddress(pageState: .editingAddress, sawWindow: true))
    }
}

private extension SiteRead {
    var site: SiteAddress? { if case .site(let s) = self { s } else { nil } }
}
