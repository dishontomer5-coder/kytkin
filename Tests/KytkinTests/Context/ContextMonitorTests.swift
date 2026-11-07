// P2-15: The thin tier-0 adapters. WorkspaceAppActivationSource is driven by fake notifications on a
// private NotificationCenter (never the real workspace one), and ContextMonitor by a fake source.
// Nothing here activates, hides or messages any app.
// P3-5 / P2-41: wake and session re-reads, the isolated deinits (no observer or timer left behind), the dead-pid flag.

import AppKit
import XCTest

@MainActor
final class WorkspaceAppActivationSourceTests: XCTestCase {
    private let me = NSRunningApplication.current

    private func post(_ name: Notification.Name, on center: NotificationCenter, app: NSRunningApplication?) {
        let info: [AnyHashable: Any]? = app.map { [NSWorkspace.applicationUserInfoKey: $0] }
        center.post(name: name, object: nil, userInfo: info)
    }

    func testStartReportsTheFrontmostAppOnce() {
        let center = NotificationCenter()
        let source = WorkspaceAppActivationSource(center: center, frontmost: { self.me })
        var seen: [(String, Int32)] = []
        source.onActivate = { seen.append(($0, $1)) }
        source.start()
        source.start() // idempotent
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, me.bundleIdentifier ?? "")
        XCTAssertEqual(seen.first?.1, me.processIdentifier)
    }

    func testNoFrontmostAppReportsNothing() {
        let source = WorkspaceAppActivationSource(center: NotificationCenter(), frontmost: { nil })
        var count = 0
        source.onActivate = { _, _ in count += 1 }
        source.start()
        XCTAssertEqual(count, 0)
    }

    func testActivateTerminateAndSpaceNotifications() {
        let center = NotificationCenter()
        let source = WorkspaceAppActivationSource(center: center, frontmost: { self.me })
        var activations: [Int32] = []
        var terminations: [Int32] = []
        source.onActivate = { _, pid in activations.append(pid) }
        source.onTerminate = { terminations.append($0) }
        source.start()
        activations.removeAll()

        post(NSWorkspace.didActivateApplicationNotification, on: center, app: me)
        post(NSWorkspace.didActivateApplicationNotification, on: center, app: nil) // no app: ignored
        post(NSWorkspace.didTerminateApplicationNotification, on: center, app: me)
        post(NSWorkspace.activeSpaceDidChangeNotification, on: center, app: nil)   // re-reads frontmost
        XCTAssertEqual(activations, [me.processIdentifier, me.processIdentifier])
        XCTAssertEqual(terminations, [me.processIdentifier])
    }

    func testStopRemovesObservers() {
        let center = NotificationCenter()
        let source = WorkspaceAppActivationSource(center: center, frontmost: { nil })
        var count = 0
        source.onActivate = { _, _ in count += 1 }
        source.start()
        source.stop()
        post(NSWorkspace.didActivateApplicationNotification, on: center, app: me)
        XCTAssertEqual(count, 0)
    }

    func testRestartObservesAgainAndReReadsTheFrontmostApp() {
        let center = NotificationCenter()
        let source = WorkspaceAppActivationSource(center: center, frontmost: { self.me })
        var count = 0
        source.onActivate = { _, _ in count += 1 }
        source.start()
        source.stop()
        source.start()
        XCTAssertEqual(count, 2)
        post(NSWorkspace.didActivateApplicationNotification, on: center, app: me)
        XCTAssertEqual(count, 3) // one observer, not two
        source.stop()
    }

    // MARK: - P2-41

    func testWakeAndSessionBecameActiveReReadTheFrontmostApp() {
        let center = NotificationCenter()
        let source = WorkspaceAppActivationSource(center: center, frontmost: { self.me })
        var count = 0
        source.onActivate = { _, _ in count += 1 }
        source.start()
        count = 0
        post(NSWorkspace.didWakeNotification, on: center, app: nil)
        post(NSWorkspace.sessionDidBecomeActiveNotification, on: center, app: nil)
        XCTAssertEqual(count, 2)
        post(NSWorkspace.sessionDidResignActiveNotification, on: center, app: nil)
        XCTAssertEqual(count, 2, "switching away reports nothing")
        source.stop()
    }

    /// Counts the observers the source leaves registered.
    private final class CountingCenter: NotificationCenter, @unchecked Sendable {
        private(set) var live = 0
        override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                                  using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
            live += 1
            return super.addObserver(forName: name, object: obj, queue: queue, using: block)
        }
        override func removeObserver(_ observer: Any) {
            live -= 1
            super.removeObserver(observer)
        }
    }

    func testReleasedWhileStartedLeavesNoObserver() {
        let center = CountingCenter()
        weak var weakSource: WorkspaceAppActivationSource?
        do {
            let source = WorkspaceAppActivationSource(center: center, frontmost: { nil })
            weakSource = source
            source.start()
            XCTAssertEqual(center.live, 5)
        }
        XCTAssertNil(weakSource)
        XCTAssertEqual(center.live, 0, "isolated deinit removed every observer")
    }
}

@MainActor
final class ContextMonitorTests: XCTestCase {
    private final class FakeSource: AppActivationSource {
        var onActivate: (@MainActor (String, Int32) -> Void)?
        var onTerminate: (@MainActor (Int32) -> Void)?
        var started = 0, stopped = 0
        func start() { started += 1 }
        func stop() { stopped += 1 }
    }

    func testForwardsDedupedContextsAndIgnoresItself() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = ContextMonitor(source: source, clock: clock, ownPID: 999, ownBundleID: "io.github.kytkin.Kytkin.dev")
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()
        XCTAssertEqual(source.started, 1)

        source.onActivate?("com.apple.Safari", 10)
        clock.advance(bySeconds: 1)
        source.onActivate?("io.github.kytkin.Kytkin.dev", 999)
        clock.advance(bySeconds: 1)
        source.onActivate?("com.apple.Safari", 10)
        clock.advance(bySeconds: 1)
        source.onActivate?("com.apple.TextEdit", 11)
        XCTAssertEqual(seen, ["com.apple.Safari", "com.apple.TextEdit"])
        XCTAssertEqual(monitor.current?.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(monitor.current?.generation, 2)

        monitor.stop()
        XCTAssertEqual(source.stopped, 1)
        XCTAssertNil(source.onActivate)
    }

    func testHeldChangeIsDeliveredByTheTimer() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = ContextMonitor(source: source, clock: clock, ownPID: 999, ownBundleID: nil,
                                     debounceNanos: 20_000_000)
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()

        source.onActivate?("A", 1)
        source.onActivate?("B", 2) // inside the window: held
        XCTAssertEqual(seen, ["A"])
        clock.advance(byMilliseconds: 20)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(seen, ["A", "B"])
        monitor.stop()
    }

    private func makeMonitor(_ source: FakeSource, _ clock: FakeClock) -> ContextMonitor {
        ContextMonitor(source: source, clock: clock, ownPID: 999, ownBundleID: "io.github.kytkin.Kytkin.dev",
                       debounceNanos: 20_000_000)
    }

    private func spin(_ seconds: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testStopCancelsAHeldChange() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()
        source.onActivate?("A", 1)
        source.onActivate?("B", 2) // held
        monitor.stop()
        clock.advance(bySeconds: 1)
        spin()
        XCTAssertEqual(seen, ["A"])

        // Restarted with Kytkin frontmost: the change held before stop() must not come back.
        monitor.start()
        source.onActivate?("io.github.kytkin.Kytkin.dev", 999)
        clock.advance(bySeconds: 1)
        spin()
        XCTAssertEqual(seen, ["A"])
        XCTAssertEqual(monitor.current?.bundleID, "A")
        monitor.stop()
    }

    func testTerminatingTheHeldAppCancelsTheTimer() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()
        source.onActivate?("A", 1)
        source.onActivate?("B", 2) // held
        source.onTerminate?(2)
        clock.advance(bySeconds: 1)
        spin()
        XCTAssertEqual(seen, ["A"])
        monitor.stop()
    }

    func testTimerThatFiresBeforeTheDeadlineRetriesAndKeepsTheFinalState() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()
        source.onActivate?("A", 1)
        source.onActivate?("B", 2)
        source.onActivate?("C", 3) // burst: only C may come out
        spin(0.1)                  // the timer fires, but the (fake) clock says it isn't due yet
        XCTAssertEqual(seen, ["A"])
        clock.advance(byMilliseconds: 20)
        spin()
        XCTAssertEqual(seen, ["A", "C"])
        spin()
        XCTAssertEqual(seen, ["A", "C"]) // exactly once
        monitor.stop()
    }

    func testKytkinFrontmostAtLaunchEmitsNothingThenTheNextAppAtOnce() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        var seen: [String] = []
        monitor.onChange = { seen.append($0.bundleID) }
        monitor.start()
        source.onActivate?("io.github.kytkin.Kytkin.dev", 999)
        XCTAssertNil(monitor.current)
        source.onActivate?("com.apple.Safari", 10) // same instant: still the leading edge
        XCTAssertEqual(seen, ["com.apple.Safari"])
        monitor.stop()
    }

    // MARK: - P3-5 / P2-41

    func testCurrentAppIsGoneFollowsTerminationAndTheNextContext() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        monitor.start()
        source.onActivate?("A", 1)
        XCTAssertFalse(monitor.currentAppIsGone)
        source.onTerminate?(1)
        XCTAssertTrue(monitor.currentAppIsGone)
        clock.advance(bySeconds: 1)
        source.onActivate?("B", 2)
        XCTAssertFalse(monitor.currentAppIsGone)
        monitor.stop()
    }

    func testOverrideHostsWithNoBrowserEmitNothing() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        let monitor = makeMonitor(source, clock)
        var seen = 0
        monitor.onChange = { _ in seen += 1 }
        monitor.start()
        source.onActivate?("A", 1)
        monitor.setHostsWithOverrides(["a.com"])
        XCTAssertEqual(seen, 1)
        monitor.stop()
    }

    func testReleasedMonitorStopsItsSourceAndTimer() {
        let source = FakeSource()
        let clock = FakeClock(nowNanos: 1)
        var seen: [String] = []
        weak var weakMonitor: ContextMonitor?
        do {
            let monitor = makeMonitor(source, clock)
            weakMonitor = monitor
            monitor.onChange = { seen.append($0.bundleID) }
            monitor.start()
            source.onActivate?("A", 1)
            source.onActivate?("B", 2)   // held: a flush timer is armed
        }
        XCTAssertNil(weakMonitor)
        XCTAssertEqual(source.stopped, 1, "isolated deinit stopped the source (its observers go with it)")
        XCTAssertNil(source.onActivate)
        XCTAssertNil(source.onTerminate)
        clock.advance(bySeconds: 1)
        spin()
        XCTAssertEqual(seen, ["A"], "the timer died with the monitor")
    }
}
