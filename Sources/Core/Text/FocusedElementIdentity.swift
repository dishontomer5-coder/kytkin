// P2-59c: An opaque handle on one focused element, so a convert can check that the focus is still the very same
// element (P3-37: the clipboard convert's shortcuts, a terminal buffer's anchor; P3-40: the undo record that first
// used it is gone). Identity only: no text, no attribute values. The live adapter compares with `CFEqual` and reads the pid with `AXUIElementGetPid`.

import Foundation

protocol FocusedElementIdentity: AnyObject {
    /// The process that owns the element. nil = unknown.
    var processID: Int32? { get }
    /// The same UI element (live: `CFEqual` on the two `AXUIElement`s; a fresh copy of the same element is equal).
    func isSameElement(as other: any FocusedElementIdentity) -> Bool
}
