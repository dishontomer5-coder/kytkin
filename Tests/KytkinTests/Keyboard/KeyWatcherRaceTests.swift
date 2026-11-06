// P2-50 QA: adversarial tests of KeyWatcher's stop timeout, the retiring tap thread and deinit off main.
// A real tap thread and run loop are started, but the backend is the fake: no tap is installed, nothing is posted.

import CoreGraphics
import XCTest

final class KeyWatcherRaceTests: XCTestCase {
    private typealias T = TapEventFactory

    // MARK: - Builder finding #1: the shared commit lock across engines

    /// A replacement's generation is armed on the commit lock that every engine of one KeyWatcher shares. After a
    /// timed-out stop and a restart, the new engine must keep counting from the old one (the late shutdown's
    /// processor becomes the seed), so the old worker's late `claimPosting` can't match the new engine's replacement.
    func testGenerationsKeepCountingAcrossATimedOutStop() {
        let log = RaceBackendLog()
        let gate = DispatchSemaphore(value: 0)
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), startTimeout: 0.3, stopTimeout: 0.3,
                                 makeBackend: { loop in log.make(loop) }, onSignal: { _ in })
        XCTAssertEqual(watcher.start(mode: .active), .active)
        typeAWordAndDoubleShift(log, 0)
        let first = watcher.processorSnapshot()?.activeGeneration
        XCTAssertNotNil(first, "a convert started on the first engine")

        log.backend(0)?.onDeviceFlags = { gate.wait() }
        watcher.perform(.reset(.contextChange)) // blocks the tap thread
        watcher.stop() // times out
        log.backend(0)?.onDeviceFlags = nil
        gate.signal()
        XCTAssertTrue(waitUntil { log.backend(0) == nil }, "the old engine is released after its thread exits")

        XCTAssertEqual(watcher.start(mode: .active), .active)
        typeAWordAndDoubleShift(log, 1)
        let second = watcher.processorSnapshot()?.activeGeneration
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertGreaterThan(second, first, "generations never restart within one KeyWatcher")
            XCTAssertFalse(watcher.claimPosting(gen: first), "the old worker's late claim can't win")
            XCTAssertTrue(watcher.claimPosting(gen: second), "the new replacement's worker still can")
        }
        watcher.stop()
    }

    // MARK: - Stop/start churn

    /// Stops that may or may not time out (a near-zero timeout races the tap thread's answer, so both the "arrived
    /// before main recorded the timeout" and the "arrived later" paths run), with operations before, during and after
    /// each stop. Main's operations must all land, in main's order, and a new backend is only ever made when the
    /// previous one has no tap installed (never two taps).
    func testStopStartChurnKeepsMainsOperationsInOrderAndNeverTwoTaps() {
        let log = RaceBackendLog()
        log.uninstallJitterMicros = 400 // around the stop timeout: the shutdown answers in time or late, at random
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), startTimeout: 3, stopTimeout: 0.000_2,
                                 makeBackend: { loop in log.make(loop) }, onSignal: { _ in })
        var n = 0
        func nextOps() -> (InputSourceID, KeyProcessorConfig) {
            n += 1
            var c = KeyProcessorConfig()
            c.doubleShift.windowNanos = UInt64(n) * 1_000
            return (InputSourceID("test.layout.\(n)"), c)
        }
        for round in 0..<200 {
            XCTAssertEqual(watcher.start(mode: round % 3 == 0 ? .listenOnly : .active),
                           round % 3 == 0 ? .listenOnly : .active, "round \(round)")
            for _ in 0..<3 {
                let (id, c) = nextOps()
                watcher.perform(.inputSourceChanged(to: id, isOurs: false))
                watcher.perform(.updateConfig(c))
            }
            if round % 4 == 0 { watcher.perform(.reset(.contextChange)) }
            watcher.stop()
            var last = nextOps()
            watcher.perform(.inputSourceChanged(to: last.0, isOurs: false)) // possibly during the gap
            watcher.perform(.updateConfig(last.1))
            if round % 2 == 0 {
                last = nextOps()
                watcher.perform(.updateConfig(last.1))
                watcher.perform(.inputSourceChanged(to: last.0, isOurs: false))
            }
            XCTAssertEqual(watcher.start(mode: .active), .active, "round \(round): the old thread exited in time")
            let snapshot = watcher.processorSnapshot()
            XCTAssertEqual(snapshot?.inputSource, last.0, "round \(round): main's last input source wins")
            XCTAssertEqual(snapshot?.config.doubleShift.windowNanos, last.1.doubleShift.windowNanos,
                           "round \(round): main's last settings win")
            XCTAssertEqual(snapshot?.mode, .active, "round \(round): updateConfig never changes the mode")
            watcher.stop()
        }
        XCTAssertFalse(log.sawTwoTaps, "a backend was made while an older one still had a tap installed")
        XCTAssertTrue(waitUntil { log.liveCount == 0 }, "every engine is released in the end")
    }

    // MARK: - deinit

    /// The last reference may go on any thread: deinit must shut the tap down there without a main-only check.
    func testDeinitOffMainShutsTheTapDown() {
        let log = RaceBackendLog()
        var watcher: KeyWatcher? = KeyWatcher(processor: KeyStreamProcessor(),
                                              makeBackend: { loop in log.make(loop) }, onSignal: { _ in })
        XCTAssertEqual(watcher?.start(mode: .active), .active)
        let box = WatcherBox(watcher!)
        watcher = nil
        let done = expectation(description: "released off main")
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            box.release()
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(waitUntil { log.backend(0) == nil }, "engine and backend released after the thread exited")
        XCTAssertEqual(log.uninstalls, 2, "the tap was removed (one uninstall precedes every install)")
    }

    /// deinit while the tap thread is stuck: it gives up after the stop timeout (no hang, no crash), and the late
    /// shutdown still removes the tap once the thread comes free.
    func testDeinitWhileTheTapThreadIsStuckDoesNotHang() {
        let log = RaceBackendLog()
        let gate = DispatchSemaphore(value: 0)
        var watcher: KeyWatcher? = KeyWatcher(processor: KeyStreamProcessor(), stopTimeout: 0.2,
                                              makeBackend: { loop in log.make(loop) }, onSignal: { _ in })
        XCTAssertEqual(watcher?.start(mode: .active), .active)
        log.backend(0)?.onDeviceFlags = { gate.wait() }
        watcher?.perform(.reset(.contextChange))
        let started = uptimeSeconds()
        watcher = nil
        XCTAssertLessThan(uptimeSeconds() - started, 2, "deinit waited only the stop timeout")
        log.backend(0)?.onDeviceFlags = nil
        gate.signal()
        XCTAssertTrue(waitUntil { log.backend(0) == nil })
        XCTAssertEqual(log.uninstalls, 2, "the late shutdown removed the tap (one uninstall precedes every install)")
    }

    /// The last reference goes on the tap thread itself (e.g. the status sink's weak `self` was the last strong
    /// one): deinit runs the shutdown inline instead of waiting on its own thread.
    func testDeinitOnTheTapThreadDoesNotDeadlock() {
        let log = RaceBackendLog()
        let box = WatcherBox(KeyWatcher(processor: KeyStreamProcessor(), stopTimeout: 5,
                                        makeBackend: { loop in log.make(loop) }, onSignal: { _ in }))
        XCTAssertEqual(box.watcher?.start(mode: .active), .active)
        let released = DispatchSemaphore(value: 0)
        let started = uptimeSeconds()
        log.onTap(0) {
            box.release() // deinit on the tap thread
            released.signal()
        }
        XCTAssertEqual(released.wait(timeout: .now() + 3), .success)
        XCTAssertLessThan(uptimeSeconds() - started, 2, "no wait on its own thread")
        XCTAssertTrue(waitUntil { log.backend(0) == nil })
        XCTAssertEqual(log.uninstalls, 2, "one uninstall precedes every install, one is the shutdown")
    }

    // MARK: - Helpers

    /// On backend `i`'s tap thread: type "a", then a quick left double-Shift (timestamps in uptime nanoseconds,
    /// just before now, so the normalizer reads them as nanoseconds on any machine).
    private func typeAWordAndDoubleShift(_ log: RaceBackendLog, _ i: Int) {
        let base = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - 1_000 * T.ms
        log.onTap(i) {
            guard let fake = log.backend(i) else { return }
            for (down, t) in [(true, UInt64(0)), (false, 20)] {
                let e = T.key(0, down: down)
                e.timestamp = base + t * T.ms
                fake.deliver(down ? .keyDown : .keyUp, e)
            }
            for (type, e) in T.doubleShift(at: 100) {
                e.timestamp = base + e.timestamp
                fake.deliver(type, e)
            }
        }
    }

    /// Uptime (stops while the Mac sleeps, as the dispatch timeouts do), so a sleep mid-test isn't counted as a hang.
    private func uptimeSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }
}

/// Holds the only strong reference to a watcher, so a test can choose the thread it is released on.
private final class WatcherBox: @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var held: KeyWatcher?
    init(_ w: KeyWatcher) { held = w }
    var watcher: KeyWatcher? { lock.withLock { held } }
    func release() {
        let w = lock.withLock { () -> KeyWatcher? in
            defer { held = nil }
            return held
        }
        _ = w // the last reference goes here, outside the lock
    }
}

/// A fresh fake per tap thread (weakly held, so a test sees an engine released) plus that thread's run loop.
private final class RaceBackendLog: @unchecked Sendable { // @unchecked: guarded by `lock`
    private final class Entry {
        weak var backend: FakeKeyTapBackend?
        let loop: CFRunLoop
        init(_ b: FakeKeyTapBackend, _ l: CFRunLoop) { backend = b; loop = l }
    }

    private let lock = NSLock()
    private var made: [Entry] = []
    private var twoTaps = false
    private var uninstallTotal = 0
    /// Each uninstall (on the tap thread) first sleeps a random 0..<this many microseconds.
    var uninstallJitterMicros: UInt32 = 0

    /// Called on main by `ensureRunning`. A previous backend that is still alive must have no tap installed.
    func make(_ loop: CFRunLoop) -> FakeKeyTapBackend {
        let fake = FakeKeyTapBackend()
        let jitter = uninstallJitterMicros
        fake.onUninstall = { [weak self] in
            if jitter > 0 { usleep(UInt32.random(in: 0..<jitter)) }
            self?.lock.withLock { self?.uninstallTotal += 1 }
        }
        lock.withLock {
            if made.contains(where: { $0.backend?.handler != nil }) { twoTaps = true }
            made.append(Entry(fake, loop))
        }
        return fake
    }

    var sawTwoTaps: Bool { lock.withLock { twoTaps } }
    var uninstalls: Int { lock.withLock { uninstallTotal } }
    var liveCount: Int { lock.withLock { made.filter { $0.backend != nil }.count } }
    func backend(_ i: Int) -> FakeKeyTapBackend? { lock.withLock { made[i].backend } }

    /// Runs `block` on backend `i`'s tap thread and waits for it.
    func onTap(_ i: Int, _ block: @escaping () -> Void) {
        let loop = lock.withLock { made[i].loop }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            block()
            done.signal()
        }
        CFRunLoopWakeUp(loop)
        _ = done.wait(timeout: .now() + 3)
    }
}
