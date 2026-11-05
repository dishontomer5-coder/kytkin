// P2-12: Counters about the event tap, shown in the About tab (001 §2.2, §7 B1/B4). Counts only, never keys.

import Foundation

struct TapHealth: Sendable, Equatable {
    /// B1: a callback slower than this counts as over budget (counted in DEBUG builds by the adapter).
    static let callbackBudgetNanos: UInt64 = 1_000_000

    var mode: TapMode = .off
    var reEnableCount = 0
    var overBudgetCallbacks = 0

    init() {}

    mutating func recordCallback(durationNanos: UInt64) {
        if durationNanos > Self.callbackBudgetNanos { overBudgetCallbacks += 1 }
    }
}
