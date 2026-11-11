// P3-42: One changed grapheme (or run of them) in a text box: its UTF-16 range in the text that was read and what replaces
// it. `BoxConversion.Plan.changes` lists them per grapheme; `ChromiumAXConvert` joins neighbours into the pieces it
// selects and types over. Held in memory for one convert only, never logged or stored (B12).

import Foundation

struct TextChange: Sendable, Equatable {
    /// UTF-16 offset of the original text (relative to the text that was read) and its length.
    let offset: Int
    let length: Int
    /// The replacement (never empty).
    let text: String

    var end: Int { offset + length }
}
