// P2-19: Counts "fights" (001 §2.2 ConflictDetector.repeatedFights): an external input-source change that
// lands less than 300 ms after one of Kytkin's own switches, the sign that something else (another
// switcher, or macOS per-document input) is switching back. Each of our switches counts at most once.
// P2-20 feeds it from SwitchController (ours = after a successful select; external = SwitchAttributor said
// `.external`). The count is for the warning only; nothing is persisted.

import Foundation

struct FightCounter: Sendable, Equatable {
    static let defaultWindowNanos: UInt64 = 300_000_000

    let windowNanos: UInt64
    private(set) var count = 0
    private var lastOurSwitchAt: UInt64?

    init(windowNanos: UInt64 = FightCounter.defaultWindowNanos) {
        self.windowNanos = windowNanos
    }

    mutating func ourSwitch(atNanos t: UInt64) {
        lastOurSwitchAt = t
    }

    /// True when this external switch counted as a fight.
    @discardableResult
    mutating func externalSwitch(atNanos t: UInt64) -> Bool {
        guard let ours = lastOurSwitchAt, t >= ours, t - ours < windowNanos else { return false }
        lastOurSwitchAt = nil
        count += 1
        return true
    }

    mutating func reset() {
        count = 0
        lastOurSwitchAt = nil
    }
}
