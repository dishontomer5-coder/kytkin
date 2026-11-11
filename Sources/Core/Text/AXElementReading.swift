// P2-18: The read half of the AX seam for one focused text element. The live adapter
// (`System/Text/AXUIElementTextElement`) has set a 0.25 s messaging timeout on the element; unit tests use fakes.
// Used only on @TextActor. Text read through it is held in memory for one replacement and never logged.

import Foundation

protocol AXElementReading: AnyObject {
    func string(_ attribute: AXTextAttribute) -> Result<String, AXAccessError>
    func integer(_ attribute: AXTextAttribute) -> Result<Int, AXAccessError>
    func range(_ attribute: AXTextAttribute) -> Result<TextRange, AXAccessError>
    func isSettable(_ attribute: AXTextAttribute) -> Result<Bool, AXAccessError>
    /// `AXStringForRange` (parameterized), so the replacer never copies the whole field.
    func string(in range: TextRange) -> Result<String, AXAccessError>
    /// Whether the element lists `AXStringForRange` among its parameterized attributes.
    func supportsStringForRange() -> Result<Bool, AXAccessError>
    /// P3-42: the names of the element's attributes (`AXUIElementCopyAttributeNames`), names only, no values. Tells a
    /// Chromium web-content node (it lists `AXDOMIdentifier` / `AXDOMClassList`) from a native one such as the omnibox.
    func attributeNames() -> Result<[String], AXAccessError>
}

extension AXElementReading {
    /// P3-42: an element that can't list its attributes is never treated as web content (the safe default).
    func attributeNames() -> Result<[String], AXAccessError> { .failure(.unsupported) }
}
