// P2-12: The tap watchdog's decision (001 §7 B4, R4 §4), pure so it can be unit-tested.
// Each time the tap is found disabled (timeout / user input, or main's 2 s `tapIsEnabled` check), ask what to do.
// 3 disables within 60 s in `active` → drop to listen-only (and warn). 3 more within 60 s → turn the tap off.
// So a bug that keeps stalling the callback can never keep freezing the keyboard.

import Foundation

struct TapHealthPolicy: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case reEnable
        case downgradeToListenOnly
        case turnOff
    }

    let limit: Int
    let windowNanos: UInt64
    /// Disable times inside the window, oldest first (at most `limit`).
    private var recent: [UInt64] = []

    init(limit: Int = 3, windowNanos: UInt64 = 60_000_000_000) {
        self.limit = max(1, limit)
        self.windowNanos = windowNanos
        recent.reserveCapacity(self.limit)
    }

    mutating func tapWasDisabled(atNanos now: UInt64, mode: TapMode) -> Action {
        guard mode != .off else { return .turnOff }
        // Keep only disables inside the window. Guard the subtraction: never underflow on odd timestamps.
        recent.removeAll { $0 > now || now - $0 >= windowNanos }
        recent.append(now)
        guard recent.count >= limit else { return .reEnable }
        // The next mode starts with a clean count ("3 more").
        recent.removeAll(keepingCapacity: true)
        return mode == .active ? .downgradeToListenOnly : .turnOff
    }

    /// The user turned the tap back on (e.g. from Settings).
    mutating func reset() {
        recent.removeAll(keepingCapacity: true)
    }
}
