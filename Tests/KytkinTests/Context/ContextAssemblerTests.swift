// P2-15: ContextAssembler: ordering, dedupe, debounce (FakeClock), own-app and empty-ID filtering,
// stale partial updates, and the Phase 3/4 fields.
// P3-5: browser observations, page state, site grace, override re-evaluation, max hold, dead pid.

import XCTest

final class ContextAssemblerTests: XCTestCase {
    private let ownPID: Int32 = 999
    private let ownID = "io.github.kytkin.Kytkin.dev"
    private var clock: FakeClock!

    override func setUp() {
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    private func makeAssembler(debounceMs: UInt64 = 120) -> ContextAssembler {
        ContextAssembler(clock: clock, ownPID: ownPID, ownBundleID: ownID, debounceNanos: debounceMs * 1_000_000)
    }

    // MARK: - Basic emission and generation

    func testFirstActivationEmitsAtOnceWithGenerationOne() throws {
        var a = makeAssembler()
        XCTAssertNil(a.current)
        let c = try XCTUnwrap(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        XCTAssertEqual(c.bundleID, "com.apple.Safari")
        XCTAssertEqual(c.pid, 10)
        XCTAssertEqual(c.generation, 1)
        XCTAssertNil(c.host)
        XCTAssertNil(c.siteDomain)
        XCTAssertNil(c.isPrivateWindow)
        XCTAssertNil(c.chatKey)
        XCTAssertEqual(a.current, c)
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testSpacedActivationsEachEmitWithIncreasingGenerations() throws {
        var a = makeAssembler()
        let ids = ["com.apple.Safari", "com.tinyspeck.slackmacgap", "com.apple.TextEdit", "com.apple.Safari"]
        for (i, id) in ids.enumerated() {
            let c = try XCTUnwrap(a.appActivated(bundleID: id, pid: Int32(10 + i)))
            XCTAssertEqual(c.bundleID, id)
            XCTAssertEqual(c.generation, UInt64(i + 1))
            clock.advance(byMilliseconds: 200)
        }
    }

    // MARK: - Dedupe

    func testSameAppAgainIsDeduped() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        XCTAssertEqual(a.current?.generation, 1)
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testDuplicateDoesNotStartABurst() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10)) // e.g. a Space-change re-read
        clock.advance(byMilliseconds: 10)
        // Still a quiet period: the duplicate didn't count as a change, so this one is immediate.
        XCTAssertEqual(try XCTUnwrap(a.appActivated(bundleID: "com.apple.TextEdit", pid: 11)).generation, 2)
    }

    func testRelaunchWithNewPIDIsAChange() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 500)
        let c = try XCTUnwrap(a.appActivated(bundleID: "com.apple.Safari", pid: 20))
        XCTAssertEqual(c.pid, 20)
        XCTAssertEqual(c.generation, 2)
    }

    // MARK: - Own app and empty IDs

    func testOwnPIDIsIgnored() {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: "com.example.whatever", pid: ownPID))
        XCTAssertNil(a.current)
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testOwnBundleIDAndPrefixAreIgnored() {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: ownID, pid: 50))
        XCTAssertNil(a.appActivated(bundleID: "io.github.kytkin.Kytkin", pid: 51))
        XCTAssertNil(a.appActivated(bundleID: "IO.GitHub.Kytkin.Helper", pid: 52))
        XCTAssertNil(a.current)
    }

    func testEmptyBlankAndBadPIDAreIgnored() {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: "", pid: 10))
        XCTAssertNil(a.appActivated(bundleID: "  \n", pid: 10))
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 0))
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: -1))
        XCTAssertNil(a.current)
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testOwnActivationBetweenTwoVisitsToTheSameAppChangesNothing() {
        // Settings opened from Safari, then closed: Safari comes back, no new Context.
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 300)
        XCTAssertNil(a.appActivated(bundleID: ownID, pid: ownPID))
        clock.advance(byMilliseconds: 300)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        XCTAssertEqual(a.current?.bundleID, "com.apple.Safari")
        XCTAssertEqual(a.current?.generation, 1)
    }

    func testIgnoredActivationDoesNotStartOrExtendABurst() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.appActivated(bundleID: ownID, pid: ownPID))
        clock.advance(byMilliseconds: 10)
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.TextEdit", pid: 11)) // immediate, not held
    }

    // MARK: - Debounce

    func testChangeInsideTheWindowIsHeldThenFlushed() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 50)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        XCTAssertEqual(a.pendingDeadlineNanos, clock.nowNanos + 120_000_000)
        XCTAssertEqual(a.current?.bundleID, "A")

        clock.advance(byMilliseconds: 119)
        XCTAssertNil(a.flushIfDue(), "not due yet")
        clock.advance(byMilliseconds: 1)
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, "B")
        XCTAssertEqual(c.generation, 2)
        XCTAssertNil(a.pendingDeadlineNanos)
        XCTAssertNil(a.flushIfDue(), "flushes once")
    }

    func testBurstEmitsOnlyTheLastAppInArrivalOrder() throws {
        // A fast swipe through Spaces: A (emitted) then B, C, D 40 ms apart.
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        for (id, pid) in [("B", Int32(2)), ("C", 3), ("D", 4)] {
            clock.advance(byMilliseconds: 40)
            XCTAssertNil(a.appActivated(bundleID: id, pid: pid))
        }
        // The deadline moved with every change.
        clock.advance(byMilliseconds: 100)
        XCTAssertNil(a.flushIfDue())
        clock.advance(byMilliseconds: 20)
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, "D")
        XCTAssertEqual(c.generation, 2, "one Context for the whole burst")
    }

    func testBurstThatReturnsToTheEmittedAppEmitsNothing() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 30)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        clock.advance(byMilliseconds: 30)
        XCTAssertNil(a.appActivated(bundleID: "A", pid: 1))
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(a.flushIfDue())
        XCTAssertEqual(a.current?.bundleID, "A")
        XCTAssertEqual(a.current?.generation, 1)
    }

    func testAfterAQuietPeriodTheNextChangeIsImmediateAgain() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 50)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        clock.advance(byMilliseconds: 120)
        XCTAssertEqual(try XCTUnwrap(a.flushIfDue()).bundleID, "B")
        clock.advance(byMilliseconds: 120)
        XCTAssertEqual(try XCTUnwrap(a.appActivated(bundleID: "C", pid: 3)).generation, 3)
    }

    func testChangeExactlyAtTheWindowEdgeIsImmediate() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 120)
        XCTAssertNotNil(a.appActivated(bundleID: "B", pid: 2))
    }

    func testZeroDebounceEmitsEveryChange() {
        var a = makeAssembler(debounceMs: 0)
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        XCTAssertNotNil(a.appActivated(bundleID: "B", pid: 2))
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        XCTAssertEqual(a.current?.generation, 3)
    }

    func testFlushWithNothingPendingIsNil() {
        var a = makeAssembler()
        XCTAssertNil(a.flushIfDue())
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
    }

    // MARK: - Termination

    func testTerminatedPendingAppIsDropped() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        a.appTerminated(pid: 2)
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
        XCTAssertEqual(a.current?.bundleID, "A")
    }

    func testTerminatingAnotherAppKeepsThePendingOne() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        a.appTerminated(pid: 1)
        clock.advance(byMilliseconds: 120)
        XCTAssertEqual(try XCTUnwrap(a.flushIfDue()).bundleID, "B")
    }

    func testDiscardPendingDropsTheHeldChangeAndTheNextChangeIsCompared() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        a.discardPending()
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
        // B is no longer "latest", so seeing it again is a real change (not deduped away).
        XCTAssertEqual(try XCTUnwrap(a.appActivated(bundleID: "B", pid: 2)).bundleID, "B")
    }

    func testTerminatingTheEmittedAppKeepsCurrent() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        a.appTerminated(pid: 1)
        XCTAssertEqual(a.current?.bundleID, "A")
    }

    // MARK: - Partial updates (Phase 3/4 shape)

    func testBrowserObservationOnTheCurrentPIDEmits() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        let c = try XCTUnwrap(a.site("docs.google.com", "google.com", isPrivate: false, pid: 10))
        XCTAssertEqual(c.bundleID, "com.apple.Safari")
        XCTAssertEqual(c.host, "docs.google.com")
        XCTAssertEqual(c.siteDomain, "google.com")
        XCTAssertEqual(c.isPrivateWindow, false)
        XCTAssertEqual(c.generation, 2)
    }

    func testBrowserObservationForAStalePIDIsDropped() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.TextEdit", pid: 11))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.site("github.com", "github.com", isPrivate: nil, pid: 10))
        XCTAssertNil(a.current?.siteDomain)
    }

    func testBrowserObservationBeforeAnyAppIsDropped() {
        var a = makeAssembler()
        XCTAssertNil(a.site("github.com", "github.com", isPrivate: nil, pid: 10))
        XCTAssertNil(a.chatChanged(ChatKey(kind: .id, value: "T1/C1"), pid: 10))
        XCTAssertNil(a.current)
    }

    func testHostChangeInsideTheSameDomainIsIgnoredWithoutAnOverride() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", isPrivate: nil, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.site("mail.google.com", "google.com", isPrivate: nil, pid: 10))
        XCTAssertEqual(a.current?.generation, 2)
    }

    func testHostChangeCountsWhenEitherHostHasAnOverride() throws {
        var a = makeAssembler()
        _ = a.setHostsWithOverrides(["mail.google.com"])
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", isPrivate: nil, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertEqual(try XCTUnwrap(a.site("Mail.Google.com.", "google.com",
                                                         isPrivate: nil, pid: 10)).host, "Mail.Google.com.")
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", isPrivate: nil, pid: 10),
                        "leaving the override host is a change too")
    }

    func testPrivateFlagChangeIsAChange() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("a.com", "a.com", isPrivate: nil, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("a.com", "a.com", isPrivate: true, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.site("a.com", "a.com", isPrivate: true, pid: 10))
    }

    func testChatChangeAndDedupe() throws {
        var a = makeAssembler()
        let key = ChatKey(kind: .id, value: "T1/C1")
        XCTAssertNotNil(a.appActivated(bundleID: "com.tinyspeck.slackmacgap", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertEqual(try XCTUnwrap(a.chatChanged(key, pid: 10)).chatKey, key)
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.chatChanged(key, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(try XCTUnwrap(a.chatChanged(nil, pid: 10)).chatKey)
        XCTAssertEqual(a.current?.generation, 3)
    }

    func testNewAppClearsSiteAndChatButSameAppKeepsThem() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNotNil(a.site("a.com", "a.com", isPrivate: false, pid: 10))
        clock.advance(byMilliseconds: 200)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        XCTAssertEqual(a.current?.siteDomain, "a.com")
        clock.advance(byMilliseconds: 200)
        let c = try XCTUnwrap(a.appActivated(bundleID: "com.apple.TextEdit", pid: 11))
        XCTAssertNil(c.host)
        XCTAssertNil(c.siteDomain)
        XCTAssertNil(c.isPrivateWindow)
        XCTAssertNil(c.chatKey)
    }

    func testPartialUpdateForAHeldAppIsMergedIntoTheFlush() throws {
        // A browser result for the newest (still held) app is not stale: it rides along in the flush.
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Safari", pid: 10))
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.site("a.com", "a.com", isPrivate: nil, pid: 10))
        clock.advance(byMilliseconds: 120)
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, "com.apple.Safari")
        XCTAssertEqual(c.siteDomain, "a.com")
        XCTAssertEqual(c.generation, 2)
    }
}

extension ContextAssembler {
    /// P3-5: a web-page observation, as the browser provider reports it (`siteKey` = domain, else host).
    mutating func site(_ host: String, _ domain: String?, isPrivate: Bool? = nil, pid: Int32,
                       pageState: BrowserPageState = .page) -> Context? {
        browserObserved(site: SiteAddress(host: host, registrableDomain: domain, isWebPage: true),
                        pageState: pageState, isPrivate: isPrivate, pid: pid)
    }
}
