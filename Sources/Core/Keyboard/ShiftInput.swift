// P2-11: The few keyboard facts DoubleShiftDetector needs, already classified by the caller
// (KeyStreamProcessor / KeyWatcher). It carries no key codes or characters, only "what kind of thing happened".
// Shift edges carry the event's own timestamp (R4: `event.timestamp`, 001: `KeyEvent.timestampNanos`), so a
// burst of queued events after a stall is timed as the user typed it, not as it arrived.

import Foundation

enum ShiftInput: Sendable, Equatable {
    /// A Shift key went down (flagsChanged, device bit 0x02 left / 0x04 right turned on).
    case shiftDown(ShiftSide, atNanos: UInt64)
    /// A Shift key went up (its device bit turned off).
    case shiftUp(ShiftSide, atNanos: UInt64)
    /// Any keyDown: Shift used as a modifier, or typing between taps.
    case otherKeyDown
    /// Cmd / Option / Control / Fn / Caps Lock changed.
    case otherModifierChanged
    /// A mouse click (so Shift-click never counts as a tap).
    case pointerDown
    /// We may have missed events: tap re-enabled, Secure Input toggled, app switched.
    case reset
}
