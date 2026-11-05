// P2-11: Tunables for DoubleShiftDetector. Defaults follow R4 / 001 (same side, 300 ms gap, 250 ms max hold).

import Foundation

struct DoubleShiftConfig: Sendable, Equatable {
    /// Which Shift keys may form a double tap. Raw values match the `doubleShiftSides` preference (001 §5).
    enum SidePolicy: String, Sendable, Equatable {
        case either, sameSide, leftOnly, rightOnly
    }

    /// Max gap, in nanoseconds, from the first tap's release to the second tap's press.
    var windowNanos: UInt64 = 300_000_000
    /// Max time, in nanoseconds, a single tap may be held (press to release).
    var maxHoldNanos: UInt64 = 250_000_000
    var sides: SidePolicy = .sameSide

    init(windowNanos: UInt64 = 300_000_000, maxHoldNanos: UInt64 = 250_000_000, sides: SidePolicy = .sameSide) {
        self.windowNanos = windowNanos
        self.maxHoldNanos = maxHoldNanos
        self.sides = sides
    }
}
