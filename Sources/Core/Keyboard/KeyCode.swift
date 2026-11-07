// P2-12: The few virtual key codes (Carbon `kVK_*`, ANSI positions) the processor classifies.
// Written out as numbers because Core may not import Carbon.

import Foundation

enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51          // Backspace
    static let escape: UInt16 = 53
    static let leftShift: UInt16 = 56
    static let rightShift: UInt16 = 60
    static let keypadEnter: UInt16 = 76
    static let help: UInt16 = 114
    static let home: UInt16 = 115
    static let pageUp: UInt16 = 116
    static let forwardDelete: UInt16 = 117
    static let end: UInt16 = 119
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126

    /// Ends a word (R5: scan back to whitespace only; `,` `.` `;` are letters on Hebrew).
    static func isWordBoundary(_ code: UInt16) -> Bool {
        code == space || code == returnKey || code == tab || code == keypadEnter
    }

    /// P2-59 (001 §12.3 X3): ends the word buffer after the word boundary. Return and keypad Enter (in a chat the
    /// message is gone, in a terminal the command ran), Tab (often moves focus) and Option-Space (may type a no-break
    /// space, which the key path would retype as U+0020). So the buffer only ever spans plain spaces.
    static func endsBuffer(_ code: UInt16, deviceFlags: UInt64) -> Bool {
        if code == returnKey || code == keypadEnter || code == tab { return true }
        return code == space && deviceFlags & KeyEvent.optionMask != 0
    }

    /// Moves the caret or deletes text we never saw, so the buffer no longer matches what is before the caret.
    static func invalidatesBuffer(_ code: UInt16) -> Bool {
        switch code {
        case home, end, pageUp, pageDown, forwardDelete, leftArrow, rightArrow, downArrow, upArrow, help: return true
        default: return false
        }
    }

    /// Keys that type nothing: Escape and the function keys F1–F20. They don't touch the buffer.
    static func typesNothing(_ code: UInt16) -> Bool {
        switch code {
        case escape, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90:
            return true
        default:
            return false
        }
    }
}
