// P2-12: One tap event as plain values (001 §2.2). The KeyWatcher adapter builds it from a CGEvent; the pure
// KeyStreamProcessor decides what to do with it. Value type, no heap, no characters: only the key code and flags.

import Foundation

struct KeyEvent: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case keyDown, keyUp, flagsChanged, pointerDown
        /// The tap was disabled (timeout / user input) and re-enabled: events may have been missed.
        case tapReset
    }

    let kind: Kind
    let keyCode: UInt16
    /// Raw `CGEventFlags` bits: device-independent masks (0x20000 Shift, 0x80000 Option, …) and
    /// device-dependent bits (0x02 left Shift, 0x04 right Shift).
    let deviceFlags: UInt64
    /// The event's own timestamp (`CGEvent.timestamp`, uptime nanoseconds). Used for double-Shift timing.
    let timestampNanos: UInt64
    let origin: EventOrigin
    let isAutoRepeat: Bool
    let commandOrControl: Bool
    let capsLock: Bool

    init(kind: Kind, keyCode: UInt16 = 0, deviceFlags: UInt64 = 0, timestampNanos: UInt64 = 0,
         origin: EventOrigin = .user, isAutoRepeat: Bool = false, commandOrControl: Bool = false,
         capsLock: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.deviceFlags = deviceFlags
        self.timestampNanos = timestampNanos
        self.origin = origin
        self.isAutoRepeat = isAutoRepeat
        self.commandOrControl = commandOrControl
        self.capsLock = capsLock
    }

    // P2-12: flag bits (IOKit IOLLEvent.h / CGEventFlags). Shift edges use the device bits, never `.maskShift`,
    // which stays set while the *other* Shift is still held (R4 §2).
    static let leftShiftDeviceBit: UInt64 = 0x02
    static let rightShiftDeviceBit: UInt64 = 0x04
    static let shiftMask: UInt64 = 0x20000
    static let optionMask: UInt64 = 0x80000

    var leftShiftDown: Bool { deviceFlags & Self.leftShiftDeviceBit != 0 }
    var rightShiftDown: Bool { deviceFlags & Self.rightShiftDeviceBit != 0 }

    /// The LayoutMap layer this key press used, from the real flags. Shift or Option wins over Caps Lock
    /// (P2-12 choice: Caps Lock + Shift types the shift layer on Apple layouts).
    var layer: KeyLayer {
        let shift = deviceFlags & Self.shiftMask != 0
        let option = deviceFlags & Self.optionMask != 0
        switch (shift, option) {
        case (true, true): return .shiftOption
        case (false, true): return .option
        case (true, false): return .shift
        case (false, false): return capsLock ? .capsLock : .plain
        }
    }
}
