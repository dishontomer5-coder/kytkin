// P3-10: The AX-thread engine with a fake tree, a fake observer and a fake timer on a fake clock (001 §14.3.4,
// B13–B15): read at once on attach, debounce, post only on change, observer retry and give-up, the Gecko bar's
// AXValueChanged dropped while it has focus, and no AX calls and no timer while detached.

import XCTest

final class FakeBrowserObserver: BrowserNotificationObserving {
    typealias Node = Int
    var onTrigger: ((BrowserTrigger) -> Void)?
    /// Answers for successive `attach` calls; true once it runs out.
    var attachAnswers: [Bool] = []
    private(set) var attachPids: [Int32] = []
    private(set) var attachTimes: [UInt64] = []
    private(set) var detachCalls = 0
    private(set) var valueWatches: [Int?] = []
    var clock: FakeClock?

    func attach(pid: Int32) -> Bool {
        attachPids.append(pid)
        attachTimes.append(clock?.nowNanos ?? 0)
        return attachAnswers.isEmpty ? true : attachAnswers.removeFirst()
    }

    func observeValueChanges(of node: Int?) { valueWatches.append(node) }
    func detach() { detachCalls += 1 }
    func post(_ t: BrowserTrigger) { onTrigger?(t) }
}

final class FakeDeadlineTimer: DeadlineTimer {
    var onFire: (() -> Void)?
    private(set) var deadline: UInt64?
    private(set) var schedules = 0

    func schedule(atNanos nanos: UInt64?) {
        deadline = nanos
        schedules += 1
    }
}

final class BrowserWatchEngineTests: XCTestCase {
    typealias Engine = BrowserWatchEngine<FakeAXTree, FakeBrowserObserver>

    private let t0: UInt64 = 1_000_000_000
    private var clock: FakeClock!
    private var timer: FakeDeadlineTimer!
    private var observers: [FakeBrowserObserver] = []
    private var trees: [Int32: FakeAXTree] = [:]
    private var treesMade: [Int32] = []
    private var delivered: DeliveryLog!
    private var siteReader: SiteReader!
    private var strategy: ProbeStrategy?
    private var zen: BrowserFixtures.Zen!

    final class DeliveryLog: @unchecked Sendable { // @unchecked: test thread only
        var items: [(pid: Int32, attachID: UInt64, observation: BrowserObservation)] = []
    }

    override func setUpWithError() throws {
        clock = FakeClock(nowNanos: t0)
        timer = FakeDeadlineTimer()
        observers = []
        treesMade = []
        delivered = DeliveryLog()
        siteReader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
        strategy = nil
        zen = BrowserFixtures.zen(focus: .page)
        trees = [7: zen.tree]
    }

    private func request(_ engine: BrowserEngine = .gecko) -> BrowserWatchRequest {
        BrowserWatchRequest(engine: engine, alwaysPrivate: false, ignorePrivateWindows: false, appleScript: nil)
    }

    private func makeEngine() -> Engine {
        let log = delivered!
        let siteReader = siteReader!
        let strategy = strategy
        return Engine(
            clock: clock, siteReader: siteReader,
            makeTree: { [unowned self] pid in
                treesMade.append(pid)
                return trees[pid] ?? FakeAXTree()
            },
            makeObserver: { [unowned self] in
                let o = FakeBrowserObserver()
                o.clock = clock
                if observers.isEmpty, let answers = pendingAttachAnswers { o.attachAnswers = answers }
                observers.append(o)
                return o
            },
            timer: timer,
            deliver: { pid, id, o in log.items.append((pid, id, o)) },
            makeReader: strategy.map { s in
                { request in
                    BrowserAddressReader(request: request, siteReader: siteReader, strategy: s,
                                         privateProbe: { (_: LatchedAXTree<FakeAXTree>, _: Int) throws(AXReadError) -> Bool? in nil })
                }
            })
    }

    private var pendingAttachAnswers: [Bool]?

    /// Moves the fake clock to the timer's deadline and fires it, as the run loop would.
    private func fire(_ engine: Engine, file: StaticString = #filePath, line: UInt = #line) {
        guard let d = timer.deadline else { return XCTFail("no timer", file: file, line: line) }
        if d > clock.nowNanos { clock.set(nowNanos: d) }
        timer.onFire?()
    }

    // MARK: - Attach

    func testNothingHappensBeforeAttach() {
        let engine = makeEngine()
        engine.trigger(.focusedElementChanged)
        engine.reread()
        engine.wake()
        engine.service()
        engine.detach()
        XCTAssertTrue(treesMade.isEmpty, "no tree, so no AX call")
        XCTAssertTrue(observers.isEmpty)
        XCTAssertNil(timer.deadline)
        XCTAssertTrue(delivered.items.isEmpty)
        XCTAssertEqual(engine.readCount, 0)
    }

    func testAttachRegistersTheObserverReadsAtOnceAndPosts() {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 3)
        XCTAssertEqual(treesMade, [7])
        XCTAssertEqual(observers.count, 1)
        XCTAssertEqual(observers[0].attachPids, [7])
        XCTAssertTrue(engine.isObserverReady)
        XCTAssertEqual(engine.readCount, 1, "the attach read runs at once, no debounce")
        XCTAssertEqual(delivered.items.count, 1)
        XCTAssertEqual(delivered.items.first?.pid, 7)
        XCTAssertEqual(delivered.items.first?.attachID, 3)
        // The app's own Gecko strategy (P3-13) reads Zen's page: a real site, so the next deadline is the 2 s poll.
        XCTAssertEqual(delivered.items.first?.observation.pageState, .page)
        XCTAssertEqual(delivered.items.first?.observation.site?.registrableDomain, "example.com")
        XCTAssertEqual(timer.deadline, t0 + 2_000_000_000, "a site was read: no readiness retry, the 2 s poll")
        XCTAssertFalse(zen.tree.calls.isEmpty)
    }

    /// The engine's plumbing for a browser that isn't ready: a stand-in strategy that always answers `.unknown` keeps
    /// the readiness retries (250 ms, 500 ms, 1 s, 2 s after the attach) going, then falls back to the 2 s poll.
    func testUnknownReadsKeepTheReadinessRetriesGoing() {
        let probe = ProbeStrategy()
        probe.scripted = .unknown
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertEqual(delivered.items.first?.observation.pageState, .unknown)
        XCTAssertEqual(timer.deadline, t0 + 250_000_000, "an .unknown read keeps the readiness retries going")
        var deadlines: [UInt64] = []
        for _ in 0..<5 {
            fire(engine)
            deadlines.append(((timer.deadline ?? t0) - t0) / 1_000_000)
        }
        XCTAssertEqual(engine.readCount, 6)
        XCTAssertEqual(probe.calls, 6)
        XCTAssertEqual(deadlines, [500, 1000, 2000, 4000, 6000], "retries at 0.25, 0.5, 1 and 2 s, then the 2 s poll")
        XCTAssertEqual(delivered.items.count, 1, "same .unknown facts: posted once")
    }

    func testDetachRemovesObserverAndTimerAndStopsAllAXCalls() {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        let observer = observers[0]
        engine.detach()
        XCTAssertEqual(observer.detachCalls, 1)
        XCTAssertNil(timer.deadline, "no timer while no browser is in front (B15)")
        XCTAssertFalse(engine.isAttached)
        zen.tree.resetCalls()
        observer.post(.focusedElementChanged)   // a late callback
        engine.trigger(.titleChanged)
        engine.wake()
        engine.reread()
        engine.service()
        XCTAssertTrue(zen.tree.calls.isEmpty, "no AX call after detach")
        XCTAssertNil(timer.deadline)
        XCTAssertEqual(delivered.items.count, 1)
    }

    func testAttachingAnotherPidDetachesTheFirstObserver() {
        let other = BrowserFixtures.arc()
        trees[9] = other.tree
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        engine.attach(pid: 9, request: request(.chromium), attachID: 2)
        XCTAssertEqual(observers.count, 2)
        XCTAssertEqual(observers[0].detachCalls, 1)
        XCTAssertNil(observers[0].onTrigger, "the old observer can't trigger reads any more")
        XCTAssertEqual(observers[1].attachPids, [9])
        XCTAssertEqual(engine.attachedPid, 9)
        XCTAssertEqual(delivered.items.map(\.attachID), [1, 2])
    }

    // MARK: - Triggers, poll, posting

    func testTriggerIsDebouncedThenReads() {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        clock.advance(byMilliseconds: 100)
        engine.trigger(.focusedElementChanged)
        XCTAssertEqual(timer.deadline, clock.nowNanos + 150_000_000)
        XCTAssertEqual(engine.readCount, 1)
        fire(engine)
        XCTAssertEqual(engine.readCount, 2)
    }

    func testPostsOnlyWhenTheFactsChange() {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        engine.trigger(.focusedElementChanged)
        fire(engine)
        XCTAssertEqual(engine.readCount, 2)
        XCTAssertEqual(delivered.items.count, 1, "same facts: not posted again")
        zen.tree.focused = zen.urlbar
        engine.trigger(.focusedElementChanged)
        fire(engine)
        XCTAssertEqual(delivered.items.count, 2)
        XCTAssertEqual(delivered.items.last?.observation.pageState, .editingAddress)
    }

    func testRereadAndWakeReadAtOnceAndAlwaysPost() {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        clock.advance(byMilliseconds: 50)
        engine.reread()
        XCTAssertEqual(engine.readCount, 2)
        XCTAssertEqual(delivered.items.count, 2, "main's site grace needs the read even if nothing changed")
        clock.advance(byMilliseconds: 50)
        engine.wake()
        XCTAssertEqual(engine.readCount, 3)
        XCTAssertEqual(delivered.items.count, 3)
    }

    func testSafetyPollEveryTwoSecondsOnceReadsSucceed() throws {
        strategy = ProbeStrategy()   // reads the page's AXURL: a real site, so the readiness retries stop
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertEqual(delivered.items.first?.observation.pageState, .page)
        XCTAssertEqual(delivered.items.first?.observation.site?.registrableDomain, "example.com")
        XCTAssertEqual(timer.deadline, t0 + 2_000_000_000)
        fire(engine)
        XCTAssertEqual(engine.readCount, 2)
        XCTAssertEqual(timer.deadline, t0 + 4_000_000_000)
        XCTAssertEqual(delivered.items.count, 1)
    }

    // MARK: - Observer retry (R2)

    func testObserverRetryBacksOffThenGivesUpWhileThePollKeepsReading() {
        pendingAttachAnswers = Array(repeating: false, count: 100)
        strategy = ProbeStrategy()
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertFalse(engine.isObserverReady)
        for _ in 0..<40 where timer.deadline != nil && clock.nowNanos < t0 + 8_000_000_000 { fire(engine) }
        let offsets = observers[0].attachTimes.map { ($0 - t0) / 1_000_000 }
        XCTAssertEqual(Array(offsets.prefix(6)), [0, 100, 300, 700, 1500, 2500], "100 ms doubling to 1 s")
        XCTAssertLessThanOrEqual(offsets.last ?? 0, 5000, "gives up after 5 s")
        XCTAssertFalse(engine.isObserverReady)
        XCTAssertGreaterThanOrEqual(engine.readCount, 4, "the 2 s poll still reads")
        XCTAssertNotNil(timer.deadline, "the poll timer stays while attached")
    }

    func testObserverRetrySucceedsLater() {
        pendingAttachAnswers = [false, false, true]
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        for _ in 0..<10 where !engine.isObserverReady { fire(engine) }   // readiness reads interleave with retries
        XCTAssertTrue(engine.isObserverReady)
        XCTAssertEqual(observers[0].attachPids.count, 3)
        XCTAssertEqual(observers[0].attachTimes.map { ($0 - t0) / 1_000_000 }, [0, 100, 300])
    }

    // MARK: - Gecko address bar

    func testGeckoBarValueChangedIsDroppedWhileTheBarHasFocus() {
        let probe = ProbeStrategy()
        let urlbar = zen.urlbar
        probe.touchWindow = { $0.addressBar = urlbar }
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(.gecko), attachID: 1)
        XCTAssertEqual(observers[0].valueWatches, [urlbar], "AXValueChanged registered on the cached bar")
        let pollDeadline = timer.deadline

        zen.tree.set(urlbar) { $0.focused = true }
        zen.tree.resetCalls()
        observers[0].post(.addressValueChanged)
        XCTAssertEqual(timer.deadline, pollDeadline, "dropped: no read scheduled")
        XCTAssertEqual(zen.tree.calls, [.isFocused(urlbar)], "only AXFocused asked, the value never fetched")

        zen.tree.set(urlbar) { $0.focused = false }
        observers[0].post(.addressValueChanged)
        XCTAssertEqual(timer.deadline, clock.nowNanos + 150_000_000, "unfocused bar: a debounced read")
    }

    func testValueWatchIsNotRegisteredForOtherEngines() {
        let probe = ProbeStrategy()
        let urlbar = zen.urlbar
        probe.touchWindow = { $0.addressBar = urlbar }
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(.chromium), attachID: 1)
        XCTAssertTrue(observers[0].valueWatches.isEmpty)
        observers[0].post(.addressValueChanged)
        XCTAssertNotEqual(timer.deadline, clock.nowNanos + 150_000_000, "no bar watched: dropped")
    }

    // MARK: - B13 through the engine

    /// A read whose browser hangs mid-way (the first timeout, with the app's own Gecko strategy) still ends, and
    /// reports `.unknown` with the window's kept site; the change from `.page` is posted. The 0.5 s wall-clock budget
    /// itself is pinned by `testEngineReadStopsOnceTheWallClockBudgetIsSpent`.
    func testEngineReadThatHangsMidWayEndsWithTheKeptSite() throws {
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertEqual(delivered.items.first?.observation.pageState, .page)
        // Focused element and main window answer; the browser hangs during the focus walk (the window was seen).
        zen.tree.hangAfterCalls = zen.tree.calls.count + 2
        engine.trigger(.titleChanged)
        fire(engine)
        XCTAssertEqual(engine.readCount, 2)
        XCTAssertEqual(delivered.items.count, 2, "the page state went from .page to .unknown")
        let last = try XCTUnwrap(delivered.items.last?.observation)
        XCTAssertEqual(last.pageState, .unknown)
        XCTAssertEqual(last.site?.registrableDomain, "example.com", "the kept site, not nil")
        XCTAssertEqual(last.via, .kept)
    }

    /// QA P3-10: the engine really arms the 0.5 s wall-clock budget (not only the first-timeout rule): a strategy
    /// that spends 0.6 s without a single timeout finds its next AX call refused without asking the browser.
    func testEngineReadStopsOnceTheWallClockBudgetIsSpent() {
        let probe = ProbeStrategy()
        let clock = clock!
        let tree = zen.tree
        nonisolated(unsafe) var refused: AXReadError?
        nonisolated(unsafe) var armed = false
        nonisolated(unsafe) var reachedTree = false
        probe.extra = { latched in
            guard armed else { return }
            clock.advance(byMilliseconds: 600)   // a slow browser: no timeout, just slow answers
            let before = tree.calls.count
            do throws(AXReadError) { _ = try latched.mainWindow() } catch { refused = error }
            reachedTree = tree.calls.count != before
        }
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertNil(refused)
        armed = true
        engine.trigger(.titleChanged)
        fire(engine)
        XCTAssertEqual(engine.readCount, 2)
        XCTAssertEqual(refused, .timedOut, "over budget: the call is refused")
        XCTAssertFalse(reachedTree, "the refused call never reached the browser")
    }

    // MARK: - QA P3-10: observer lifetime and retry edges

    func testDetachDuringObserverRetryStopsRetryingAndLeavesNoTimer() {
        pendingAttachAnswers = Array(repeating: false, count: 100)
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        XCTAssertNotNil(timer.deadline)
        engine.detach()
        XCTAssertNil(timer.deadline, "no retry timer once detached (B15)")
        clock.advance(bySeconds: 10)
        engine.service()
        engine.wake()
        XCTAssertEqual(observers[0].attachPids, [7], "no registration attempt after detach")
        XCTAssertEqual(observers[0].detachCalls, 1)
    }

    func testRetryForTheOldPidNeverRegistersOnTheNewOne() {
        pendingAttachAnswers = Array(repeating: false, count: 100)   // the first observer only
        trees[9] = BrowserFixtures.arc().tree
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        clock.advance(byMilliseconds: 50)
        engine.attach(pid: 9, request: request(.chromium), attachID: 2)
        for _ in 0..<10 where timer.deadline != nil && clock.nowNanos < t0 + 6_000_000_000 { fire(engine) }
        XCTAssertEqual(observers[0].attachPids, [7], "pid 7's retry died with its attach")
        XCTAssertEqual(observers[0].detachCalls, 1)
        XCTAssertEqual(observers[1].attachPids, [9])
        XCTAssertTrue(engine.isObserverReady)
    }

    func testWakeRetriesAnObserverThatGaveUp() {
        pendingAttachAnswers = Array(repeating: false, count: 9) + [true]
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(), attachID: 1)
        for _ in 0..<40 where timer.deadline != nil && clock.nowNanos < t0 + 8_000_000_000 { fire(engine) }
        XCTAssertFalse(engine.isObserverReady)
        let triesBeforeWake = observers[0].attachPids.count
        XCTAssertEqual(triesBeforeWake, 8, "0, 100, 300, 700, 1500, 2500, 3500, 4500 ms, then gave up")
        engine.wake()
        XCTAssertEqual(observers[0].attachPids.count, 9, "wake tries again at once")
        engine.wake()
        XCTAssertEqual(observers[0].attachPids.count, 9, "a retry is already pending: no extra try")
        fire(engine)
        for _ in 0..<5 where !engine.isObserverReady { fire(engine) }
        XCTAssertTrue(engine.isObserverReady, "the restarted schedule gets there")
    }

    func testGeckoBarIsWatchedOnceAnObserverRegistersLate() {
        pendingAttachAnswers = [false, true]
        let probe = ProbeStrategy()
        let urlbar = zen.urlbar
        probe.touchWindow = { $0.addressBar = urlbar }
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(.gecko), attachID: 1)
        XCTAssertTrue(observers[0].valueWatches.isEmpty, "no observer yet, nothing registered")
        for _ in 0..<5 where !engine.isObserverReady { fire(engine) }
        XCTAssertTrue(engine.isObserverReady)
        XCTAssertEqual(observers[0].valueWatches, [urlbar], "the cached bar is registered as soon as the observer is")
    }

    func testGeckoBarWatchIsClearedWhenTheBarGoesAway() {
        let probe = ProbeStrategy()
        let urlbar = zen.urlbar
        nonisolated(unsafe) var bar: Int? = urlbar
        probe.touchWindow = { $0.addressBar = bar }
        strategy = probe
        let engine = makeEngine()
        engine.attach(pid: 7, request: request(.gecko), attachID: 1)
        bar = nil
        engine.trigger(.focusedWindowChanged)
        fire(engine)
        XCTAssertEqual(observers[0].valueWatches, [urlbar, nil], "the old bar's AXValueChanged is removed")
        zen.tree.resetCalls()
        observers[0].post(.addressValueChanged)   // a late one from the old bar
        XCTAssertTrue(zen.tree.calls.isEmpty, "dropped without an AX call")
    }
}
