// P3-35: What one whole-box convert writes (001 §12.3 X11): one range of a `FieldWindow`, from the first to the last
// character that changes, and where the caret goes afterwards. Ranges only, no text.

import Foundation

struct FieldEdit: Sendable, Equatable {
    /// UTF-16 offset and length of the range to replace, relative to the window's text.
    let offset: Int
    let length: Int
    /// Absolute UTF-16 caret after the write: the user's caret, moved by any length change before it. nil = right
    /// after the written text (the range ends at the caret, as a P2-59 run did).
    let caretAfter: Int?
}
