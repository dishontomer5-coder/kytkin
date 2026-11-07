// P3-7: The Automation fallback in the AX-thread plumbing: the scheduler's rate-limit retry, the engine giving the
// reader a session only for a request with a dialect and reading again when a send was held back, and the watcher
// opening the gate for the attached pid only (closed on detach, for a request without a dialect, and on release).

import XCTest

final class AppleEventSchedulerTests: XCTestCase {
    private let t0: UInt64 = 1_000_000_000

    func testReadAgainIsADeadlineAndIsConsumed() {
        var s = BrowserReadScheduler()
        s.readAgain(at: t0)
        XCTAssertNil(s.nextDeadlineNanos, "nothing while detached")
        s.attached(now: t0)
        XCTAssertTrue(s.takeDue(now: t0))
        s.readFinished(.init(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL), sawWindow: true, now: t0)
        s.readAgain(at: t0 + 1_000_000_000)
        s.readAgain(at: t0 + 1_500_000_000)   // the earliest wins
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 1_000_000_000)
        XCTAssertTrue(s.takeDue(now: t0 + 1_000_000_000))
        XCTAssertEqual(s.nextDeadlineNanos, t0 + 1_000_000_000 + BrowserReadScheduler.pollNanos)
    }
}

final class AppleEventEngineTests: XCTestCase {
    typealias Engine = BrowserWatchEngine<FakeAXTree, FakeBrowserObserver>
    private let t0: UInt64 = 10_000_000_000

    private func coldChromium() -> FakeAXTree {
        let t = FakeAXTree()
        let app = t.add("AXApplication")
        let window = t.add("AXWindow", subrole: "AXStandardWindow", under: app)
        t.focused = t.add("AXButton", under: t.add("AXGroup", under: window))
        t.main = window
        return t
    }

    private func run(dialect: AppleScriptDialect?) throws -> (FakeAppleEventSender, FakeDeadlineTimer, FakeClock,
                                                             Engine) {
        let clock = FakeClock(nowNanos: t0)
        let timer = FakeDeadlineTimer()
        let sender = FakeAppleEventSender()
        let gate = AppleEventSendGate()
        gate.allow(pid: 7)
        let tree = coldChromium()
        let engine = Engine(clock: clock, siteReader: SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled)),
                            makeTree: { _ in tree }, makeObserver: { FakeBrowserObserver() }, timer: timer,
                            deliver: { _, _, _, _ in },
                            appleEvents: AppleEventFallback(sender: sender, gate: gate))
        engine.attach(pid: 7, request: BrowserWatchRequest(engine: .chromium, alwaysPrivate: false,
                                                           ignorePrivateWindows: false, appleScript: dialect),
                      attachID: 1)
        return (sender, timer, clock, engine)
    }

    func testNoDialectNoSends() throws {
        let (sender, _, _, _) = try run(dialect: nil)
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testAHeldBackSendIsRetriedWhenTheLimitAllows() throws {
        let (sender, timer, clock, engine) = try run(dialect: .chromium)   // keep the engine: the timer holds it weakly
        XCTAssertEqual(sender.privateSends, 1, "the attach read asks the private flag first")
        XCTAssertEqual(sender.addressSends, 0)
        // The 250 ms readiness retry comes first and is still inside the limit; the 1 s retry then sends.
        var fires = 0
        while sender.addressSends == 0, fires < 10, let d = timer.deadline, d <= t0 + 1_000_000_000 {
            fires += 1
            clock.set(nowNanos: max(d, clock.nowNanos))
            timer.onFire?()
        }
        XCTAssertEqual(sender.addressSends, 1)
        XCTAssertEqual(clock.nowNanos, t0 + 1_000_000_000)
        XCTAssertTrue(engine.isAttached)
    }
}

@MainActor
final class AppleEventGateWatcherTests: XCTestCase {
    private let chrome = BrowserWatchRequest(engine: .chromium, alwaysPrivate: false, ignorePrivateWindows: false,
                                             appleScript: .chromium)
    private let plain = BrowserWatchRequest(engine: .chromium, alwaysPrivate: false, ignorePrivateWindows: false,
                                            appleScript: nil)

    private func makeWatcher(_ gate: AppleEventSendGate) -> BrowserWatcher {
        let engine = FakeWatchEngine()
        let executor = ManualAXExecutor()
        return BrowserWatcher(makeThread: { executor }, makeEngine: { _ in engine }, postToMain: { _ in },
                              appleEventGate: gate)
    }

    func testGateFollowsTheAttach() {
        let gate = AppleEventSendGate()
        let w = makeWatcher(gate)
        w.attach(pid: 7, bundleID: "com.google.Chrome", request: chrome)
        XCTAssertTrue(gate.allows(7))
        w.attach(pid: 8, bundleID: "com.google.Chrome", request: chrome)
        XCTAssertFalse(gate.allows(7), "only the browser in front")
        XCTAssertTrue(gate.allows(8))
        w.attach(pid: 8, bundleID: "com.google.Chrome", request: plain)   // turned off, paused or revoked
        XCTAssertFalse(gate.allows(8))
        w.attach(pid: 8, bundleID: "com.google.Chrome", request: chrome)
        w.detach()
        XCTAssertFalse(gate.allows(8), "closed at once on main, before the AX thread hears of it")
    }

    func testReleasedWatcherClosesTheGate() {
        let gate = AppleEventSendGate()
        var w: BrowserWatcher? = makeWatcher(gate)
        w?.attach(pid: 7, bundleID: "com.google.Chrome", request: chrome)
        XCTAssertTrue(gate.allows(7))
        w = nil
        XCTAssertFalse(gate.allows(7))
    }
}
