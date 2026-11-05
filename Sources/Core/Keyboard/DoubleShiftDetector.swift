// P2-11: Pure double-Shift state machine, ported from our own R4 sketch (docs/research/keyboard-event-tap.md §2).
// Fires on the second Shift *release*, never the press, so a second press that turns into Shift+letter doesn't count.
// Time comes from the injected `Clock`, read once per input, so tests drive it with FakeClock.

import Foundation

struct DoubleShiftDetector: Sendable {
    private enum State: Equatable {
        case idle
        case firstDown(ShiftSide, at: UInt64)
        case waitingSecond(ShiftSide, upAt: UInt64)
        case secondDown(ShiftSide, at: UInt64)
        /// Something disqualified the current gesture; wait until every Shift is up.
        case spoiled
    }

    let config: DoubleShiftConfig
    private let clock: any Clock
    private var state: State = .idle
    private var shiftsHeld = 0

    init(config: DoubleShiftConfig = .init(), clock: any Clock) {
        self.config = config
        self.clock = clock
    }

    /// Returns true exactly once per completed double tap, on the second Shift release.
    mutating func handle(_ input: ShiftInput) -> Bool {
        switch input {
        case .reset:
            state = .idle
            shiftsHeld = 0
            return false

        case .otherKeyDown, .otherModifierChanged, .pointerDown:
            // Shift held while something else happens = Shift used as a modifier.
            state = shiftsHeld > 0 ? .spoiled : .idle
            return false

        case let .shiftDown(side):
            let now = clock.nowNanos
            shiftsHeld += 1
            // Both Shifts at once is a chord, not a tap.
            if shiftsHeld > 1 || !allowed(side) {
                state = .spoiled
                return false
            }
            if case let .waitingSecond(first, upAt) = state,
               config.sides != .sameSide || first == side,
               let gap = elapsed(from: upAt, to: now), gap <= config.windowNanos {
                state = .secondDown(side, at: now)
            } else {
                // Too slow, other side, or no first tap: this press starts a new gesture.
                state = .firstDown(side, at: now)
            }
            return false

        case let .shiftUp(side):
            let now = clock.nowNanos
            shiftsHeld = max(0, shiftsHeld - 1)
            switch state {
            case let .firstDown(s, at) where s == side:
                if let hold = elapsed(from: at, to: now), hold <= config.maxHoldNanos {
                    state = .waitingSecond(side, upAt: now)
                } else {
                    state = .idle
                }
                return false
            case let .secondDown(s, at) where s == side:
                state = .idle
                guard let hold = elapsed(from: at, to: now) else { return false }
                return hold <= config.maxHoldNanos
            default:
                if shiftsHeld == 0 { state = .idle }
                return false
            }
        }
    }

    private func allowed(_ side: ShiftSide) -> Bool {
        switch config.sides {
        case .leftOnly: return side == .left
        case .rightOnly: return side == .right
        case .either, .sameSide: return true
        }
    }

    /// P2-11: nil when time went backwards. R4 found a UInt64 underflow crash here, so never subtract unguarded
    /// (a clock fed from event timestamps can deliver them out of order).
    private func elapsed(from start: UInt64, to end: UInt64) -> UInt64? {
        end >= start ? end - start : nil
    }
}
