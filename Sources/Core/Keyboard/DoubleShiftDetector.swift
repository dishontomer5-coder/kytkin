// P2-11: Pure double-Shift state machine, ported from our own R4 sketch (docs/research/keyboard-event-tap.md §2).
// Fires on the second Shift *release*, never the press, so a second press that turns into Shift+letter doesn't count.
// Time comes from each Shift input's event timestamp, so it is deterministic in tests and immune to tap latency.

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
    private var state: State = .idle
    /// Held state per side, not a counter: a lost release then heals on that side's next press
    /// instead of leaving the detector stuck in "chord" until the next reset.
    private var leftHeld = false
    private var rightHeld = false

    init(config: DoubleShiftConfig = .init()) {
        self.config = config
    }

    /// Returns true exactly once per completed double tap, on the second Shift release.
    mutating func handle(_ input: ShiftInput) -> Bool {
        switch input {
        case .reset:
            state = .idle
            leftHeld = false
            rightHeld = false
            return false

        case .otherKeyDown, .otherModifierChanged, .pointerDown:
            // Shift held while something else happens = Shift used as a modifier.
            state = anyHeld ? .spoiled : .idle
            return false

        case let .shiftDown(side, now):
            setHeld(side, true)
            // Both Shifts at once is a chord, not a tap.
            if isHeld(side.other) || !allowed(side) {
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

        case let .shiftUp(side, now):
            setHeld(side, false)
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
                if !anyHeld { state = .idle }
                return false
            }
        }
    }

    private var anyHeld: Bool { leftHeld || rightHeld }

    private func isHeld(_ side: ShiftSide) -> Bool {
        side == .left ? leftHeld : rightHeld
    }

    private mutating func setHeld(_ side: ShiftSide, _ held: Bool) {
        if side == .left { leftHeld = held } else { rightHeld = held }
    }

    private func allowed(_ side: ShiftSide) -> Bool {
        switch config.sides {
        case .leftOnly: return side == .left
        case .rightOnly: return side == .right
        case .either, .sameSide: return true
        }
    }

    /// P2-11: nil when time went backwards. R4 found a UInt64 underflow crash here, so never subtract unguarded
    /// (event timestamps can arrive out of order).
    private func elapsed(from start: UInt64, to end: UInt64) -> UInt64? {
        end >= start ? end - start : nil
    }
}
