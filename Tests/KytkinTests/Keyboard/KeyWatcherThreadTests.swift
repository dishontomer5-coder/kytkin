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
        let watcher = makeWatcher()
        watcher.start(mode: .active)
        let ran = expectation(description: "ran on the tap thread")
        watcher.perform { _ in
            XCTAssertEqual(Thread.current.name, KeyTapThread.name)
            XCTAssertFalse(Thread.isMainThread)
            ran.fulfill()
        }
        wait(for: [ran], timeout: 2)
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
        watcher.perform { $0.inputSourceChanged(to: hebrew, isOurs: false) }
        watcher.start(mode: .active)
        let checked = expectation(description: "seed carried over")
        watcher.perform { p in
            XCTAssertEqual(p.inputSource, hebrew)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 2)
        watcher.stop()
    }

    func testClaimPostingWorksFromAnyThread() {
        let watcher = makeWatcher()
        XCTAssertFalse(watcher.claimPosting(gen: 1), "nothing armed: abandon")
    }
}
