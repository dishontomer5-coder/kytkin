// P3-5: ContextAssembler Phase 3 API and P2-41 hardening (001 §14.5), all on a FakeClock: the 500 ms max hold for an
// endless burst, the 150 ms site grace (combined emission, or app-only with `.unknown`), page state, stale pids,
// `setHostsWithOverrides` re-evaluation, and the "current app has quit" flag.

import XCTest

final class ContextAssemblerPhase3Tests: XCTestCase {
    private var clock: FakeClock!
    private let zen = "app.zen-browser.zen"

    override func setUp() {
        clock = FakeClock(nowNanos: 1_000_000_000)
    }

    private func makeAssembler() -> ContextAssembler {
        ContextAssembler(clock: clock, ownPID: 999, ownBundleID: "io.github.kytkin.Kytkin.dev")
    }

    private func ms(_ v: UInt64) -> UInt64 { v * 1_000_000 }

    // MARK: - P2-41 max hold

    func testEndlessBurstStillEmitsWithin500ms() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))   // leading edge
        clock.advance(byMilliseconds: 50)
        let firstHeld = clock.nowNanos
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        var emitted: [(String, UInt64)] = []
        // A change every 50 ms for 2 s (three apps in turn): the 120 ms debounce alone would never fire.
        let ids: [(String, Int32)] = [("B", 2), ("C", 3), ("D", 4)]
        for i in 0..<40 {
            clock.advance(byMilliseconds: 50)
            if let c = a.flushIfDue() { emitted.append((c.bundleID, clock.nowNanos)) }
            let (id, pid) = ids[i % 3]
            if let c = a.appActivated(bundleID: id, pid: pid) { emitted.append((c.bundleID, clock.nowNanos)) }
            if let deadline = a.pendingDeadlineNanos {
                XCTAssertLessThanOrEqual(deadline, (emitted.last?.1 ?? firstHeld) + ms(550))
            }
        }
        XCTAssertGreaterThanOrEqual(emitted.count, 3, "about one emission per 500 ms")
        XCTAssertLessThanOrEqual(try XCTUnwrap(emitted.first).1 - firstHeld, ms(500))
        for (prev, next) in zip(emitted, emitted.dropFirst()) {
            XCTAssertLessThanOrEqual(next.1 - prev.1, ms(550), "one emission per max hold (plus one 50 ms step)")
        }
    }

    func testMaxHoldCapsTheDeadline() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 10)
        let firstHeld = clock.nowNanos
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        XCTAssertEqual(a.pendingDeadlineNanos, firstHeld + ms(120))
        for i in 0..<4 {   // 100 ms steps: 400 ms in, the deadline is capped at +500
            clock.advance(byMilliseconds: 100)
            XCTAssertNil(a.flushIfDue())
            XCTAssertNil(a.appActivated(bundleID: i.isMultiple(of: 2) ? "C" : "B", pid: i.isMultiple(of: 2) ? 3 : 2))
        }
        XCTAssertEqual(a.pendingDeadlineNanos, firstHeld + ms(500))
        clock.set(nowNanos: firstHeld + ms(500))
        XCTAssertNotNil(a.flushIfDue())
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testAChangeAfterTheMaxHoldPassedEmitsAtOnce() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 10)
        let firstHeld = clock.nowNanos
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        // The flush timer is late (a busy main thread) and changes keep coming 100 ms apart.
        for (i, id) in ["C", "B", "C", "B"].enumerated() {
            clock.advance(byMilliseconds: 100)
            XCTAssertNil(a.appActivated(bundleID: id, pid: id == "C" ? 3 : 2), "step \(i)")
        }
        clock.set(nowNanos: firstHeld + ms(510))
        let c = try XCTUnwrap(a.appActivated(bundleID: "C", pid: 3), "past the max hold: emitted, not held again")
        XCTAssertEqual(c.bundleID, "C")
        XCTAssertNil(a.pendingDeadlineNanos)
    }

    func testAShortBurstStillUsesTheDebounce() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 10)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2))
        clock.advance(byMilliseconds: 119)
        XCTAssertNil(a.flushIfDue())
        clock.advance(byMilliseconds: 1)
        XCTAssertEqual(try XCTUnwrap(a.flushIfDue()).bundleID, "B")
    }

    // MARK: - Site grace (D4)

    func testBrowserActivationIsHeldForItsFirstReadAndEmittedWithIt() throws {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        XCTAssertNil(a.current)
        XCTAssertEqual(a.pendingDeadlineNanos, clock.nowNanos + ContextAssembler.siteGraceNanos)
        clock.advance(byMilliseconds: 20)
        let c = try XCTUnwrap(a.site("www.ynet.co.il", "ynet.co.il", isPrivate: false, pid: 20))
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertEqual(c.host, "www.ynet.co.il")
        XCTAssertEqual(c.siteDomain, "ynet.co.il")
        XCTAssertEqual(c.isPrivateWindow, false)
        XCTAssertEqual(c.pageState, .page)
        XCTAssertEqual(c.generation, 1, "one Context: app and site together")
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
    }

    func testGraceRunsOutAppOnlyWithUnknownPageStateThenTheReadFollows() throws {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        clock.advance(byMilliseconds: 149)
        XCTAssertNil(a.flushIfDue())
        clock.advance(byMilliseconds: 1)
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertNil(c.siteDomain)
        XCTAssertEqual(c.pageState, .unknown)
        clock.advance(byMilliseconds: 200)
        let d = try XCTUnwrap(a.site("ynet.co.il", "ynet.co.il", pid: 20))
        XCTAssertEqual(d.siteDomain, "ynet.co.il")
        XCTAssertEqual(d.pageState, .page)
        XCTAssertEqual(d.generation, 2)
    }

    func testGraceAfterAnEmissionWaitsAndReleasesOnTheRead() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true), "not the leading edge: it waits")
        clock.advance(byMilliseconds: 5)
        XCTAssertEqual(try XCTUnwrap(a.site("a.com", "a.com", pid: 20)).siteDomain, "a.com")
    }

    func testAStaleReadDoesNotReleaseTheGrace() {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        clock.advance(byMilliseconds: 10)
        XCTAssertNil(a.site("a.com", "a.com", pid: 21))
        XCTAssertNotNil(a.pendingDeadlineNanos)
        XCTAssertNil(a.current)
    }

    func testGraceInsideABurstMergesTheReadAndFlushesAtTheBurstDeadline() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        let activatedAt = clock.nowNanos
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        XCTAssertEqual(a.pendingDeadlineNanos, activatedAt + ms(150), "the later of debounce (120) and grace (150)")
        clock.advance(byMilliseconds: 20)
        XCTAssertNil(a.site("a.com", "a.com", pid: 20), "the burst still holds it")
        XCTAssertEqual(a.pendingDeadlineNanos, activatedAt + ms(120))
        clock.set(nowNanos: activatedAt + ms(120))
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, zen)
        XCTAssertEqual(c.siteDomain, "a.com")
        XCTAssertEqual(c.pageState, .page)
        XCTAssertEqual(c.generation, 2)
    }

    func testGraceInsideABurstWithNoReadIsUnknownAtTheGraceDeadline() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(byMilliseconds: 20)
        let activatedAt = clock.nowNanos
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        clock.set(nowNanos: activatedAt + ms(120))
        XCTAssertNil(a.flushIfDue(), "the grace is longer than the debounce")
        clock.set(nowNanos: activatedAt + ms(150))
        XCTAssertEqual(try XCTUnwrap(a.flushIfDue()).pageState, .unknown)
    }

    func testANewAppReplacesTheGrace() throws {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        clock.advance(byMilliseconds: 30)
        XCTAssertNil(a.appActivated(bundleID: "com.apple.Notes", pid: 30))   // inside the window: held
        XCTAssertNil(a.site("a.com", "a.com", pid: 20), "stale: the browser isn't the newest app")
        clock.advance(byMilliseconds: 120)
        let c = try XCTUnwrap(a.flushIfDue())
        XCTAssertEqual(c.bundleID, "com.apple.Notes")
        XCTAssertNil(c.pageState, "not a browser: no page state")
        XCTAssertEqual(c.generation, 1)
    }

    func testABrowserThatQuitsDuringTheGraceIsDropped() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        a.appTerminated(pid: 20)
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
        XCTAssertEqual(a.current?.bundleID, "A")
        XCTAssertFalse(a.currentAppIsGone, "A is still running")
    }

    func testSameBrowserAgainKeepsItsSiteAndStartsNoGrace() throws {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        XCTAssertNotNil(a.site("a.com", "a.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true), "back from Kytkin's window")
        XCTAssertNil(a.pendingDeadlineNanos)
        XCTAssertEqual(a.current?.siteDomain, "a.com")
    }

    // MARK: - QA (P3-5 + P3-6 merge)

    func testBrowserObservationOverloadMapsEveryField() throws {
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        let o = BrowserObservation(site: SiteAddress(host: "news.ynet.co.il", registrableDomain: "ynet.co.il",
                                                     isWebPage: true),
                                   pageState: .editingAddress, isPrivate: true, via: .addressBar)
        XCTAssertNil(a.browserObserved(o, pid: 21), "stale pid")
        let c = try XCTUnwrap(a.browserObserved(o, pid: 20))
        XCTAssertEqual(c.host, "news.ynet.co.il")
        XCTAssertEqual(c.siteDomain, "ynet.co.il")
        XCTAssertEqual(c.isPrivateWindow, true)
        XCTAssertEqual(c.pageState, .editingAddress)
        XCTAssertEqual(c.generation, 1)
    }

    func testAnUnknownFirstReadReleasesTheGraceAtOnceAndTheLaterSiteIsOneMoreContext() throws {
        // Documents the cold-start path: the first read can't tell (readiness retries follow on the AX thread), so the
        // grace ends early with the app's rule; the site, when read, is a second Context (no flip back afterwards).
        var a = makeAssembler()
        XCTAssertNil(a.appActivated(bundleID: zen, pid: 20, awaitsSite: true))
        clock.advance(byMilliseconds: 10)
        let first = try XCTUnwrap(a.browserObserved(.unknown(), pid: 20))
        XCTAssertEqual(first.pageState, .unknown)
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(byMilliseconds: 250)
        let second = try XCTUnwrap(a.site("a.com", "a.com", pid: 20))
        XCTAssertEqual(second.siteDomain, "a.com")
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
        XCTAssertEqual(a.current?.generation, 2)
    }

    // MARK: - Page state

    func testPageStateOnlyChangeIsEmittedWithTheSiteKept() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("a.com", "a.com", pid: 20))
        clock.advance(bySeconds: 1)
        let c = try XCTUnwrap(a.site("a.com", "a.com", pid: 20, pageState: .editingAddress))
        XCTAssertEqual(c.pageState, .editingAddress)
        XCTAssertEqual(c.siteDomain, "a.com")
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.site("a.com", "a.com", pid: 20, pageState: .editingAddress), "deduped")
        clock.advance(bySeconds: 1)
        XCTAssertEqual(try XCTUnwrap(a.site("a.com", "a.com", pid: 20)).pageState, .page)
    }

    func testNotWebPageClearsTheSite() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("a.com", "a.com", pid: 20))
        clock.advance(bySeconds: 1)
        let c = try XCTUnwrap(a.browserObserved(site: .notWebPage, pageState: .notWebPage, isPrivate: nil, pid: 20))
        XCTAssertNil(c.host)
        XCTAssertNil(c.siteDomain)
        XCTAssertEqual(c.pageState, .notWebPage)
    }

    func testSiteKeyFallsBackToTheHost() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        let c = try XCTUnwrap(a.site("192.168.1.1", nil, pid: 20))
        XCTAssertEqual(c.host, "192.168.1.1")
        XCTAssertEqual(c.siteDomain, "192.168.1.1", "SiteAddress.siteKey: an IP is its own site")
    }

    func testANewAppClearsThePageState() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("a.com", "a.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNil(try XCTUnwrap(a.appActivated(bundleID: "com.apple.Notes", pid: 30)).pageState)
    }

    // MARK: - hostsWithOverrides

    func testAddingAnOverrideForTheObservedHostEmitsAtOnce() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.site("mail.google.com", "google.com", pid: 20), "no override: same site")
        XCTAssertEqual(a.current?.host, "docs.google.com")
        clock.advance(bySeconds: 1)
        let c = try XCTUnwrap(a.setHostsWithOverrides(["Mail.Google.com."]), "normalized like the rules")
        XCTAssertEqual(c.host, "mail.google.com")
        XCTAssertEqual(c.generation, 3)
        XCTAssertEqual(a.hostsWithOverrides, ["mail.google.com"])
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.setHostsWithOverrides(["mail.google.com"]), "nothing new")
    }

    func testAnOverrideForTheEmittedHostEmitsTheNewerObservedHost() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.site("mail.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        // The override is for the host Kytkin still has (docs), but the user is on mail now: mail is the truth.
        XCTAssertEqual(try XCTUnwrap(a.setHostsWithOverrides(["docs.google.com"])).host, "mail.google.com")
    }

    func testRemovingAnOverrideEmitsNothingAndLaterHostChangesAreIgnoredAgain() throws {
        var a = makeAssembler()
        XCTAssertNil(a.setHostsWithOverrides(["mail.google.com"]), "no app yet")
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("mail.google.com", "google.com", pid: 20), "override host: a change")
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.setHostsWithOverrides([]), "the emitted host is the observed one")
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.site("docs.google.com", "google.com", pid: 20))
        XCTAssertEqual(a.current?.host, "mail.google.com")
    }

    func testOverrideReEvaluationWithoutABrowserDoesNothing() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Notes", pid: 30))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.setHostsWithOverrides(["a.com"]))
    }

    func testObservedHostIsForgottenOnAppChange() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.site("docs.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.site("mail.google.com", "google.com", pid: 20))
        clock.advance(bySeconds: 1)
        XCTAssertNotNil(a.appActivated(bundleID: "com.apple.Notes", pid: 30))
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.setHostsWithOverrides(["mail.google.com"]))
    }

    // MARK: - P2-41 dead pid

    func testTerminatingTheEmittedAppSetsTheFlagUntilTheNextEmission() throws {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: "A", pid: 1))
        a.appTerminated(pid: 2)
        XCTAssertFalse(a.currentAppIsGone, "another app")
        a.appTerminated(pid: 1)
        XCTAssertTrue(a.currentAppIsGone)
        XCTAssertEqual(a.current?.bundleID, "A", "current is kept (Pin/Forget still act on its rules)")
        clock.advance(byMilliseconds: 10)
        XCTAssertNil(a.appActivated(bundleID: "B", pid: 2), "held by the debounce")
        XCTAssertTrue(a.currentAppIsGone, "not emitted yet")
        clock.advance(byMilliseconds: 120)
        XCTAssertNotNil(a.flushIfDue())
        XCTAssertFalse(a.currentAppIsGone)
    }

    func testDeadFlagSurvivesAHeldChangeOfTheSameAppBeingDropped() {
        var a = makeAssembler()
        XCTAssertNotNil(a.appActivated(bundleID: zen, pid: 20))
        XCTAssertNil(a.site("a.com", "a.com", pid: 20), "held: right after the activation")
        a.appTerminated(pid: 20)
        XCTAssertTrue(a.currentAppIsGone)
        XCTAssertNil(a.pendingDeadlineNanos)
        clock.advance(bySeconds: 1)
        XCTAssertNil(a.flushIfDue())
        XCTAssertNil(a.current?.siteDomain)
    }
}
