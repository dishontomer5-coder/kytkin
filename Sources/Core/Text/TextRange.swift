// P2-18: A text range in UTF-16 units, the unit AX uses for `AXSelectedTextRange` and `AXStringForRange`.
// Core's stand-in for `CFRange`, so the AX seam needs no CoreFoundation types.

import Foundation

struct TextRange: Sendable, Equatable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    var end: Int { location + length }

    /// A caret: an empty range.
    var isCaret: Bool { length == 0 }
}
