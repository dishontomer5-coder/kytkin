// P3-10: The main-actor watcher's hop logic (001 §14.1, B16): attach/detach/wake go to the AX thread without
// waiting, attachIDs, the same pid + request → just a read, stale results dropped, the thread made lazily, and a
// released watcher detaching its engine. A hand-drained executor and a fake engine stand in for the AX thread.

import XCTest

/// Queues blocks; the test runs them when it wants (the AX thread "later").
final class ManualAXExecutor: AXThreadExecuting, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { blocks.count } }

    func async(_ block: @escaping @Sendable () -> Void) {
        lock.withLock { blocks.append(block) }
    }

    func drain() {
        while true {
            let next: (@Sendable () -> Void)? = lock.withLock { blocks.isEmpty ? nil : blocks.removeFirst() }
            guard let next else { return }
            next()
        }
    }
}

final class FakeWatchEngine: BrowserWatchEngineDriving, @unchecked Sendable { // @unchecked: guarded by `lock`
    enum Call: Equatable {
        case attach(Int32, BrowserWatchRequest, UInt64), reread, wake, detach
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    var deliver: (@Sendable (Int32, UInt64, BrowserObservation) -> Void)?

    func attach(pid: Int32, request: BrowserWatchRequest, attachID: UInt64) {
        lock.withLock { _calls.append(.attach(pid, request, attachID)) }
    }
    func reread() { lock.withLock { _calls.append(.reread) } }
    func wake() { lock.withLock { _calls.append(.wake) } }
    func detach() { lock.withLock { _calls.append(.detach) } }
}

/// Collects main-actor blocks the watcher posts; the test runs them.
final class MainPostQueue: @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var blocks: [@Sendable @MainActor () -> Void] = []

    func post(_ block: @escaping @Sendable @MainActor () -> Void) { lock.withLock { blocks.append(block) } }

    @MainActor func drain() {
        let all = lock.withLock { defer { blocks = [] }; return blocks }
        for b in all { b() }
    }
}

@MainActor
final class BrowserWatcherTests: XCTestCase {
    private var executor: ManualAXExecutor!
    private var engine: FakeWatchEngine!
    private var mainQueue: MainPostQueue!
    private var threadsMade = 0
    private var received: [(Int32, UInt64, BrowserObservation)] = []

    private let gecko = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                            appleScript: nil)
    private let geckoIgnoringPrivate = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false,
                                                           ignorePrivateWindows: true, appleScript: nil)
    private let site = BrowserObservation(site: SiteAddress(host: "www.example.com", registrableDomain: "example.com",
                                                            isWebPage: true),
                                          pageState: .page, isPrivate: nil, via: .axURL)

    override func setUp() {
        executor = ManualAXExecutor()
        engine = FakeWatchEngine()
        mainQueue = MainPostQueue()
        threadsMade = 0
        received = []
    }

    private func makeWatcher() -> BrowserWatcher {
        let executor = executor!
        let engine = engine!
        let queue = mainQueue!
        let w = BrowserWatcher(
            makeThread: { [unowned self] in
                threadsMade += 1
                return executor
            },
            makeEngine: { deliver in
                engine.deliver = deliver
                return engine
            },
            postToMain: { block in queue.post(block) })
        w.onObservation = { [unowned self] pid, id, o in received.append((pid, id, o)) }
        return w
    }

    func testThreadIsMadeOnTheFirstAttachOnly() {
        let w = makeWatcher()
        w.detach()
        w.wake()
        XCTAssertEqual(threadsMade, 0, "no AX thread until a browser is in front")
        XCTAssertEqual(executor.pendingCount, 0)
        w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        w.attach(pid: 2, bundleID: "org.mozilla.firefox", request: gecko)
        XCTAssertEqual(threadsMade, 1)
    }

    func testAttachHopsWithoutWaiting() {
        let w = makeWatcher()
        let id = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        XCTAssertEqual(id, 1)
        XCTAssertTrue(engine.calls.isEmpty, "attach returned before the AX thread did anything (B16)")
        executor.drain()
        XCTAssertEqual(engine.calls, [.attach(1, gecko, 1)])
    }

    func testSamePidAndRequestIsJustARead() {
        let w = makeWatcher()
        let first = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        let again = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        XCTAssertEqual(again, first)
        let changed = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: geckoIgnoringPrivate)
        XCTAssertEqual(changed, first + 1, "a changed request re-attaches")
        let otherPid = w.attach(pid: 2, bundleID: "app.zen-browser.zen", request: geckoIgnoringPrivate)
        XCTAssertEqual(otherPid, first + 2)
        executor.drain()
        XCTAssertEqual(engine.calls, [.attach(1, gecko, 1), .reread, .attach(1, geckoIgnoringPrivate, 2),
                                      .attach(2, geckoIgnoringPrivate, 3)])
        XCTAssertEqual(w.currentAttachID, 3)
    }

    func testDetachAndWakeHop() {
        let w = makeWatcher()
        w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        w.wake()
        w.detach()
        w.detach()   // already detached: nothing more
        w.wake()     // detached: nothing
        executor.drain()
        XCTAssertEqual(engine.calls, [.attach(1, gecko, 1), .wake, .detach])
        XCTAssertNil(w.currentAttachID)
        // Attaching the same pid again after a detach is a fresh attach with a new id.
        XCTAssertEqual(w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko), 2)
    }

    func testResultsReachMainAsynchronouslyAndStaleOnesAreDropped() throws {
        let w = makeWatcher()
        w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        executor.drain()
        let deliver = try XCTUnwrap(engine.deliver)
        deliver(1, 1, site)
        XCTAssertTrue(received.isEmpty, "posted to main, not delivered inline")
        mainQueue.drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, 1)
        XCTAssertEqual(received.first?.1, 1)
        XCTAssertEqual(received.first?.2, site)

        w.attach(pid: 2, bundleID: "com.google.Chrome", request: gecko)
        deliver(1, 1, site)          // read for the old attach, arriving late
        deliver(2, 1, site)          // wrong attachID
        deliver(1, 2, site)          // wrong pid
        mainQueue.drain()
        XCTAssertEqual(received.count, 1, "stale results dropped")
        deliver(2, 2, site)
        mainQueue.drain()
        XCTAssertEqual(received.count, 2)

        w.detach()
        deliver(2, 2, site)
        mainQueue.drain()
        XCTAssertEqual(received.count, 2, "nothing is delivered after detach")
    }

    func testReleasedWatcherDetachesItsEngine() {
        var w: BrowserWatcher? = makeWatcher()
        w?.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        executor.drain()
        weak let weakWatcher = w
        w = nil
        XCTAssertNil(weakWatcher)
        executor.drain()
        XCTAssertEqual(engine.calls.last, .detach, "no observer or timer left behind")
    }

    func testReleasedWatcherThatNeverAttachedSendsNothing() {
        var w: BrowserWatcher? = makeWatcher()
        w = nil
        XCTAssertNil(w)
        XCTAssertEqual(executor.pendingCount, 0)
        XCTAssertEqual(threadsMade, 0)
    }

    func testDeliverAfterTheWatcherIsGoneIsHarmless() throws {
        var w: BrowserWatcher? = makeWatcher()
        w?.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        executor.drain()
        let deliver = try XCTUnwrap(engine.deliver)
        w = nil
        deliver(1, 1, site)
        mainQueue.drain()
        XCTAssertTrue(received.isEmpty)
    }

    // MARK: - QA P3-10

    /// A → B → A quickly: A's first attach and its late result never win over the newest attach of the same pid.
    func testRapidSwitchBackDropsTheOldAttachOfTheSamePid() throws {
        let w = makeWatcher()
        let a1 = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        let b = w.attach(pid: 2, bundleID: "com.google.Chrome", request: gecko)
        let a2 = w.attach(pid: 1, bundleID: "app.zen-browser.zen", request: gecko)
        XCTAssertEqual([a1, b, a2], [1, 2, 3], "coming back to A is a fresh attach, not a reread of the old one")
        executor.drain()
        XCTAssertEqual(engine.calls, [.attach(1, gecko, 1), .attach(2, gecko, 2), .attach(1, gecko, 3)])
        let deliver = try XCTUnwrap(engine.deliver)
        let other = BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .axURL)
        deliver(1, 1, other)   // read for A's first attach, arriving after the switch back
        deliver(2, 2, other)   // B's
        deliver(1, 3, site)
        mainQueue.drain()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.1, 3)
        XCTAssertEqual(received.first?.2, site)
    }

    /// The real AX thread and engine: the watcher is released while the engine is in the middle of a read. The read
    /// finishes, its result is dropped on main, and the queued detach then leaves nothing attached.
    func testReleasingTheWatcherMidReadIsSafe() {
        final class Box: @unchecked Sendable { // @unchecked: written on the AX thread, read after a hop back
            var engine: BrowserWatchEngine<FakeAXTree, FakeBrowserObserver>?
            var observer: FakeBrowserObserver?
            var reads = 0
        }
        let box = Box()
        let gate = DispatchSemaphore(value: 0)
        let inRead = expectation(description: "the engine is mid-read")
        let zen = BrowserFixtures.zen(focus: .page)
        let probe = ProbeStrategy()
        probe.extra = { _ in
            box.reads += 1
            guard box.reads == 1 else { return }
            inRead.fulfill()
            gate.wait()   // test only: holds the AX thread inside the first read
        }
        let thread = AXThread()
        let siteReader = SiteReader(extractor: DomainExtractor.bundled!)
        var w: BrowserWatcher? = BrowserWatcher(
            makeThread: {
                thread.start()
                return thread
            },
            makeEngine: { deliver in
                let clock = SystemClock()
                let engine = BrowserWatchEngine<FakeAXTree, FakeBrowserObserver>(
                    clock: clock, siteReader: siteReader,
                    makeTree: { _ in zen.tree },
                    makeObserver: {
                        let o = FakeBrowserObserver()
                        box.observer = o
                        return o
                    },
                    timer: RunLoopDeadlineTimer(clock: clock), deliver: deliver,
                    makeReader: { request in
                        BrowserAddressReader(request: request, siteReader: siteReader, strategy: probe,
                                             privateProbe: { (_: LatchedAXTree<FakeAXTree>, _: Int) throws(AXReadError) -> Bool? in nil })
                    })
                box.engine = engine
                return engine
            })
        nonisolated(unsafe) var got = 0
        w?.onObservation = { _, _, _ in got += 1 }
        w?.attach(pid: 7, bundleID: "app.zen-browser.zen", request: gecko)
        wait(for: [inRead], timeout: 2)
        w = nil   // isolated deinit queues engine.detach() behind the read in flight
        gate.signal()
        let checked = expectation(description: "checked on the AX thread")
        nonisolated(unsafe) var attachedAfter = true
        nonisolated(unsafe) var observerDetaches = 0
        thread.async {
            attachedAfter = box.engine?.isAttached ?? true
            observerDetaches = box.observer?.detachCalls ?? 0
            DispatchQueue.main.async { checked.fulfill() }   // after the read's own post to main
        }
        wait(for: [checked], timeout: 2)
        XCTAssertFalse(attachedAfter, "the released watcher's engine detached")
        XCTAssertEqual(observerDetaches, 1)
        XCTAssertEqual(got, 0, "the read's result went nowhere: its watcher is gone")
        let stopped = expectation(description: "released")
        thread.async {
            box.engine = nil
            box.observer = nil
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        thread.stopRunLoop()
    }
}
