// P2-17: KeyWatcher's thread hops with a fake backend (the real one isn't even compiled into the tests).
// A real tap thread and run loop are started, but no tap is installed and nothing is posted.

import XCTest

final class KeyWatcherThreadTests: XCTestCase {
    private func makeWatcher(granted: Set<TapMode> = [.active, .listenOnly],
                             onStatus: @Sendable @escaping (KeyWatcherStatus) -> Void = { _ in }) -> KeyWatcher {
        KeyWatcher(processor: KeyStreamProcessor(), makeBackend: { _ in
            let fake = FakeKeyTapBackend()
            fake.granted = granted
            return fake
        }, onSignal: { _ in }, onStatus: onStatus)
    }

    func testStartReturnsTheAchievedMode() {
        let watcher = makeWatcher()
        XCTAssertEqual(watcher.start(mode: .active), .active)
        XCTAssertEqual(watcher.health.mode, .active)
        XCTAssertEqual(watcher.start(mode: .listenOnly), .listenOnly, "a second start switches modes")
        watcher.stop()
        XCTAssertEqual(watcher.health.mode, .off)
    }

    func testWithoutPermissionStartIsOff() {
        let watcher = makeWatcher(granted: [])
        XCTAssertEqual(watcher.start(mode: .active), .off)
        watcher.stop()
    }

    func testPerformRunsOnTheTapThread() {
        let fake = FakeKeyTapBackend()
        let ranOn = ThreadNameBox()
        fake.onDeviceFlags = { ranOn.set(Thread.current.name) } // a reset reads the flags on the tap thread
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), makeBackend: { _ in fake }, onSignal: { _ in })
        watcher.start(mode: .active)
        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        watcher.perform(.inputSourceChanged(to: hebrew, isOurs: false))
        watcher.perform(.reset(.contextChange))
        XCTAssertEqual(watcher.processorSnapshot()?.inputSource, hebrew)
        XCTAssertEqual(ranOn.get(), KeyTapThread.name)
        watcher.stop()
    }

    func testStatusIsDeliveredOnMain() {
        let delivered = expectation(description: "status on main")
        delivered.assertForOverFulfill = false
        let watcher = makeWatcher(onStatus: { status in
            XCTAssertTrue(Thread.isMainThread)
            if status.health.mode == .active { delivered.fulfill() }
        })
        watcher.start(mode: .active)
        wait(for: [delivered], timeout: 2)
        watcher.stop()
    }

    func testHopsBeforeStartAreKeptForTheProcessor() {
        let watcher = makeWatcher()
        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        watcher.perform(.inputSourceChanged(to: hebrew, isOurs: false))
        XCTAssertEqual(watcher.processorSnapshot()?.inputSource, hebrew)
        watcher.start(mode: .active)
        XCTAssertEqual(watcher.processorSnapshot()?.inputSource, hebrew, "seed carried over")
        watcher.stop()
        XCTAssertEqual(watcher.processorSnapshot()?.inputSource, hebrew, "and kept after a stop")
    }

    func testClaimPostingWorksFromAnyThread() {
        let watcher = makeWatcher()
        XCTAssertFalse(watcher.claimPosting(gen: 1), "nothing armed: abandon")
    }

    // MARK: - P2-47: a start that times out can't install a tap later

    /// The tap thread is stuck before the start's apply even began: start reports `.off`, and when the thread
    /// comes free the queued apply ends in `.off` too (the earlier tap is removed, nothing new is installed).
    func testAStartThatTimesOutBeforeItRunsEndsOff() {
        let fake = FakeKeyTapBackend()
        let gate = DispatchSemaphore(value: 0)
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), startTimeout: 0.5, makeBackend: { _ in fake },
                                 onSignal: { _ in })
        XCTAssertEqual(watcher.start(mode: .active), .active)
        fake.onDeviceFlags = { gate.wait() }
        watcher.perform(.reset(.contextChange)) // blocks the tap thread on the gate
        XCTAssertEqual(watcher.start(mode: .listenOnly), .off, "the tap thread didn't answer in time")
        fake.onDeviceFlags = nil
        gate.signal()
        _ = watcher.processorSnapshot() // waits for the queued apply
        XCTAssertEqual(watcher.status.health.mode, .off)
        XCTAssertEqual(fake.installs, [.active], "the late apply never installed the listen-only tap")
        XCTAssertNil(fake.handler)
        watcher.stop()
    }

    /// The apply already began (stuck inside `install`) when main gave up: it is undone right after it finishes.
    func testAStartThatTimesOutWhileInstallingIsUndone() {
        let fake = FakeKeyTapBackend()
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        fake.onInstall = {
            entered.signal()
            gate.wait()
        }
        let statuses = StatusLog()
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), startTimeout: 0.5, makeBackend: { _ in fake },
                                 onSignal: { _ in }, onStatus: { statuses.append($0.health.mode) })
        XCTAssertEqual(watcher.start(mode: .active), .off)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success, "the apply had begun")
        fake.onInstall = nil
        gate.signal()
        _ = watcher.processorSnapshot()
        XCTAssertEqual(fake.installs, [.active])
        XCTAssertNil(fake.handler, "the tap installed after main gave up was removed again")
        XCTAssertFalse(fake.enabled)
        XCTAssertEqual(watcher.status.health.mode, .off)
        let published = expectation(description: "statuses reach main")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(statuses.last, .off, "main's last word agrees with what start returned")
        XCTAssertEqual(watcher.start(mode: .active), .active, "a later start works normally")
        watcher.stop()
    }

    /// A start answered in time is unaffected: no undo afterwards.
    func testAStartAnsweredInTimeIsKept() {
        let fake = FakeKeyTapBackend()
        let watcher = KeyWatcher(processor: KeyStreamProcessor(), startTimeout: 5, makeBackend: { _ in fake },
                                 onSignal: { _ in })
        XCTAssertEqual(watcher.start(mode: .active), .active)
        _ = watcher.processorSnapshot()
        XCTAssertEqual(watcher.status.health.mode, .active)
        XCTAssertNotNil(fake.handler)
        watcher.stop()
    }
}

/// Cross-thread test boxes (the tap thread writes, the test reads after a barrier).
private final class ThreadNameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    func set(_ n: String?) { lock.withLock { name = n } }
    func get() -> String? { lock.withLock { name } }
}

private final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [TapMode] = []
    func append(_ m: TapMode) { lock.withLock { modes.append(m) } }
    var last: TapMode? { lock.withLock { modes.last } }
}
