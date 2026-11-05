// P2-11: The few keyboard facts DoubleShiftDetector needs, already classified by the caller
// (KeyStreamProcessor / KeyWatcher). It carries no key codes or characters, only "what kind of thing happened".
// Time is not carried here: the detector reads its injected `Clock` when each input arrives.

import Foundation

enum ShiftInput: Sendable, Equatable {
    /// A Shift key went down (flagsChanged, device bit 0x02 left / 0x04 right turned on).
    case shiftDown(ShiftSide)
    /// A Shift key went up (its device bit turned off).
    case shiftUp(ShiftSide)
    /// Any keyDown: Shift used as a modifier, or typing between taps.
    case otherKeyDown
    /// Cmd / Option / Control / Fn / Caps Lock changed.
    case otherModifierChanged
    /// A mouse click (so Shift-click never counts as a tap).
    case pointerDown
    /// We may have missed events: tap re-enabled, Secure Input toggled, app switched.
    case reset
}
