// P2-59c: An opaque handle on one focused element, so the run convert's undo record (`ConvertController.LastRun`,
// 001 §12.3 X6) can check on the next double-Shift that the focus is still the very same element. Identity only:
// no text, no attribute values. The live adapter compares with `CFEqual` and reads the pid with `AXUIElementGetPid`.

import Foundation

protocol FocusedElementIdentity: AnyObject {
    /// The process that owns the element. nil = unknown (the undo record is then never kept).
    var processID: Int32? { get }
    /// The same UI element (live: `CFEqual` on the two `AXUIElement`s; a fresh copy of the same element is equal).
    func isSameElement(as other: any FocusedElementIdentity) -> Bool
}
