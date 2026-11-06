// P2-18: The AX seam's entry point: the system-wide focused element, with the messaging timeout already set
// on it (001 §7 B5). Never prompts for Accessibility; without it, it answers `.notTrusted`.

import Foundation

protocol FocusedElementProviding: AnyObject {
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError>
}
