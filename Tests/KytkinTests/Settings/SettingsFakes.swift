// P2-23: Fakes for the Settings tests. Nothing here touches SMAppService, System Settings or the window server.

import Foundation

@MainActor final class FakeLoginItems: LoginItemManaging {
    enum Call: Equatable { case status, register, unregister, openSystemSettings }

    private(set) var calls: [Call] = []
    var current: LoginItemStatus = .notRegistered
    /// What `register` leaves behind (macOS may ask for approval).
    var statusAfterRegister: LoginItemStatus = .enabled
    /// What `unregister` leaves behind.
    var statusAfterUnregister: LoginItemStatus = .notRegistered
    var registerError: Error?
    var unregisterError: Error?

    struct Failure: Error {}

    var status: LoginItemStatus {
        calls.append(.status)
        return current
    }

    func register() throws {
        calls.append(.register)
        if let registerError {
            if statusAfterRegister == .requiresApproval { current = .requiresApproval }
            throw registerError
        }
        current = statusAfterRegister
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError { throw unregisterError }
        current = statusAfterUnregister
    }

    func openSystemSettingsLoginItems() { calls.append(.openSystemSettings) }

    /// Only the calls that change something (register / unregister / open).
    var actions: [Call] { calls.filter { $0 != .status } }
}

/// One-shot timer on the FakeClock: `advance` moves the clock and fires a handler that has come due.
@MainActor final class FakeOneShot: OneShotScheduling {
    private let clock: FakeClock
    private var pending: (deadline: UInt64, handler: @MainActor () -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    init(clock: FakeClock) { self.clock = clock }

    var isScheduled: Bool { pending != nil }

    func schedule(afterNanos: UInt64, _ handler: @escaping @MainActor () -> Void) {
        scheduleCount += 1
        pending = (clock.nowNanos + afterNanos, handler)
    }

    func cancel() {
        cancelCount += 1
        pending = nil
    }

    func advance(byMilliseconds ms: UInt64) {
        clock.advance(byMilliseconds: ms)
        guard let p = pending, clock.nowNanos >= p.deadline else { return }
        pending = nil
        p.handler()
    }
}
