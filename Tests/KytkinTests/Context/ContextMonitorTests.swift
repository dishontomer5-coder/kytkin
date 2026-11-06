// P2-15: The thin tier-0 adapters. WorkspaceAppActivationSource is driven by fake notifications on a
// private NotificationCenter (never the real workspace one), and ContextMonitor by a fake source.
// Nothing here activates, hides or messages any app.

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
}
