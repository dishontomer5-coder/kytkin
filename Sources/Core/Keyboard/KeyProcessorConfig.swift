// P2-12: Tunables for KeyStreamProcessor. Defaults are the 001 §7 B2/B3 budgets.

import Foundation

struct KeyProcessorConfig: Sendable, Equatable {
    var doubleShift: DoubleShiftConfig = .init()
    var doubleShiftEnabled = true
    /// P4: hold back Space / Return / Tab after a word for auto-fix. Off until auto-fix exists.
    var autoFixEnabled = false
    /// Convert hold-back deadline; then the FIFO flushes unchanged.
    var convertDeadlineNanos: UInt64 = 400_000_000
    /// Auto-fix hold-back deadline; then the trigger and the FIFO flush unchanged.
    var autoFixDeadlineNanos: UInt64 = 150_000_000
    /// After the worker has started posting (B3 commit won), force a flush this long after the deadline.
    var postingHardCapNanos: UInt64 = 1_000_000_000
    /// Clamped to 1...32 by HoldBackQueue.
    var holdBackCapacity = HoldBackQueue.maxCapacity
    /// The tap mode the processor starts in.
    var mode: TapMode = .active

    init() {}
}
