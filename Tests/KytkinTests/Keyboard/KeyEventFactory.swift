// P2-12: Builds synthetic KeyEvents for processor tests. Times are in milliseconds for readability.

import Foundation

enum KeyEventFactory {
    static let ms: UInt64 = 1_000_000
    static let left: UInt64 = KeyEvent.leftShiftDeviceBit | KeyEvent.shiftMask
    static let right: UInt64 = KeyEvent.rightShiftDeviceBit | KeyEvent.shiftMask

    static func key(_ code: UInt16, flags: UInt64 = 0, at t: UInt64 = 0, origin: EventOrigin = .user,
                    command: Bool = false, capsLock: Bool = false, autoRepeat: Bool = false) -> KeyEvent {
        KeyEvent(kind: .keyDown, keyCode: code, deviceFlags: flags, timestampNanos: t * ms, origin: origin,
                 isAutoRepeat: autoRepeat, commandOrControl: command, capsLock: capsLock)
    }

    static func keyUp(_ code: UInt16, at t: UInt64 = 0, origin: EventOrigin = .user) -> KeyEvent {
        KeyEvent(kind: .keyUp, keyCode: code, timestampNanos: t * ms, origin: origin)
    }

    /// A flagsChanged event with the given raw flags (key code = the modifier that changed).
    static func flags(_ code: UInt16, _ flags: UInt64, at t: UInt64, origin: EventOrigin = .user) -> KeyEvent {
        KeyEvent(kind: .flagsChanged, keyCode: code, deviceFlags: flags, timestampNanos: t * ms, origin: origin)
    }

    /// Press and release of one Shift key, with no other modifier held.
    static func shiftTap(_ side: ShiftSide, down: UInt64, up: UInt64) -> [KeyEvent] {
        let code = side == .left ? KeyCode.leftShift : KeyCode.rightShift
        let bits = side == .left ? left : right
        return [flags(code, bits, at: down), flags(code, 0, at: up)]
    }

    /// A quick double tap of the left Shift starting at `t` ms.
    static func doubleShift(at t: UInt64 = 0) -> [KeyEvent] {
        shiftTap(.left, down: t, up: t + 50) + shiftTap(.left, down: t + 150, up: t + 200)
    }

    static func pointer(at t: UInt64 = 0) -> KeyEvent {
        KeyEvent(kind: .pointerDown, timestampNanos: t * ms)
    }
}
