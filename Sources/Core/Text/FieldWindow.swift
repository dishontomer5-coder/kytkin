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

extension FieldWindow {
    /// P3-62 (owner 2026-11-17: no selection → the text from the box's start up to the cursor): this window cut at the
    /// caret. The part after the caret is never planned (a mail's quoted thread, a signature, the rest of a document).
    var upToCaret: FieldWindow {
        let units = Array(text.utf16)
        let keep = max(0, min(units.count, caret - location))
        return FieldWindow(text: String(decoding: units[..<keep], as: UTF16.self), location: location, caret: caret,
                           reachesFieldStart: reachesFieldStart, reachesFieldEnd: keep == units.count && reachesFieldEnd)
    }
}
