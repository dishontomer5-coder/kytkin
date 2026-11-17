// P6-0j: the app that owns the system-wide focused UI element (AX), which is not always the frontmost app: Spotlight
// and other system panels take the keys while `frontmostApplication` stays the app behind them. Identity only (a pid
// and a bundle ID): nothing is read from the element.

import Foundation

struct FocusOwner: Sendable, Equatable {
    let pid: Int32
    let bundleID: String
}
