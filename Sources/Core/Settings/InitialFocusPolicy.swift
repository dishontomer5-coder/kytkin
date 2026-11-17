// P6-0h (QA): When Settings may clear a focus ring it didn't ask for.
//
// AppKit and SwiftUI pick a first key view when the window shows or a tab appears, sometimes a moment later, so the
// window clears the first responder at once and again after 0, 0.1 and 0.35 s. Those late clears must never take
// the focus from something the user chose in that time: a click into the (empty) Rules search, a Tab to a control.
// So each late clear only runs if no key or mouse-down reached the window since it was scheduled, and never while a
// field holds text.
//
// Facts in, decision out (the UI reads the window's first responder and its input count).

import Foundation

enum InitialFocusPolicy {
    /// The delays of the late clears, after the immediate one.
    static let lateClearDelays: [TimeInterval] = [0.0, 0.1, 0.35]

    /// - Parameters:
    ///   - hasFocus: something other than the window itself is first responder.
    ///   - editingText: that responder is a field editor holding text.
    ///   - inputsWhenScheduled / inputsNow: the window's count of key and mouse-down events then and now.
    static func shouldClear(hasFocus: Bool, editingText: Bool, inputsWhenScheduled: Int, inputsNow: Int) -> Bool {
        guard hasFocus, !editingText else { return false }
        return inputsNow == inputsWhenScheduled
    }
}
