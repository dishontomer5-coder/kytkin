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
    /// P3-44: the texts of inline elements inside this text box that must stay whole when the box converts: Slack
    /// mention pills (`@Hillel Banai`, `#channel`) and links. Bounded walk (≤ `maxNodes` descendants). Text is held for
    /// one convert only and never logged. P3-46: each with its AX role (for the DEBUG trace, as a role name only).
    /// P3-53: `budgetNanos`: the most wall-clock time the walks may take (what is left of the convert's read budget,
    /// 001 §7 B5). P3-62: no mail-quote walk any more (the convert stops at the cursor).
    func inlineAtoms(maxNodes: Int, budgetNanos: UInt64) -> Result<[InlineAtom], AXAccessError>
    /// P4-5b: `AXFocused` (read only).
    func isFocused() -> Result<Bool, AXAccessError>
}

/// P3-46: one inline element that must stay whole (a mention pill, a channel link, a link). `text` is held for one
/// convert only and never logged; `role` is the element's AX role name (`AXStaticText`, `AXLink`, `AXGroup`…).
struct InlineAtom: Sendable, Equatable {
    let text: String
    let role: String
}

extension AXElementReading {
    /// P3-42: an element that can't list its attributes is never treated as web content (the safe default).
    func attributeNames() -> Result<[String], AXAccessError> { .failure(.unsupported) }
    /// P3-44: an element that can't list its inline elements has none (`BoxConversion`'s `@word` rule still holds).
    func inlineAtoms(maxNodes: Int, budgetNanos: UInt64) -> Result<[InlineAtom], AXAccessError> {
        .failure(.unsupported)
    }
    /// P4-5b: `AXFocused` (read only), for a walked chat composer's "still focused" check. Unknown by default.
    func isFocused() -> Result<Bool, AXAccessError> { .failure(.unsupported) }
}
