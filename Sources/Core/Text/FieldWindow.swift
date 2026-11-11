// P3-35: The text box as read for one double-Shift (001 §12.3 X11): the whole field when it fits the cap, else a
// window around the caret. Held in memory for that one convert only, never logged or stored (CLAUDE.md, B12).

import Foundation

struct FieldWindow: Sendable, Equatable {
    let text: String
    /// Absolute UTF-16 offset of `text`'s first unit.
    let location: Int
    /// Absolute UTF-16 offset of the caret; `location ≤ caret ≤ location + text.utf16.count`.
    let caret: Int
    /// `text` starts at the beginning of the field.
    let reachesFieldStart: Bool
    /// `text` ends at the end of the field. False when the field is bigger than the window, or when the field's length
    /// couldn't be read (the window then ends at the caret).
    let reachesFieldEnd: Bool
}
