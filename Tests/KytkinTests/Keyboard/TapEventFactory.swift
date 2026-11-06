// P2-17: Builds CGEvents for the KeyWatcher plumbing tests. They are created in memory only and NEVER posted
// (live-machine rule): `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with a nil source touches nothing.
// Times are in milliseconds for readability.

import CoreGraphics
import Foundation

enum TapEventFactory {
    static let ms: UInt64 = 1_000_000

    static func key(_ code: UInt16, down: Bool = true, flags: UInt64 = 0, at t: UInt64 = 0,
                    marker: Int64 = 0) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        e.flags = CGEventFlags(rawValue: flags)
        e.timestamp = t * ms
        if marker != 0 { e.setIntegerValueField(.eventSourceUserData, value: marker) }
        return e
    }

    static func flagsChanged(_ code: UInt16, _ flags: UInt64, at t: UInt64) -> CGEvent {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        e.timestamp = t * ms
        return e
    }

    static func mouseDown(at t: UInt64 = 0) -> CGEvent {
        let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero,
                        mouseButton: .left)!
        e.timestamp = t * ms
        return e
    }

    /// A quick left double-Shift starting at `t` ms, as (type, event) pairs.
    static func doubleShift(at t: UInt64) -> [(CGEventType, CGEvent)] {
        let down = KeyEvent.leftShiftDeviceBit | KeyEvent.shiftMask
        return [(t, down), (t + 50, 0), (t + 150, down), (t + 200, 0)].map {
            (.flagsChanged, flagsChanged(KeyCode.leftShift, $0.1, at: $0.0))
        }
    }
}
