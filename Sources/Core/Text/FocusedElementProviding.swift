// P2-18: The AX seam's entry point: the system-wide focused element, with the messaging timeout already set
// on it (001 §7 B5). Never prompts for Accessibility; without it, it answers `.notTrusted`.

import Foundation

protocol FocusedElementProviding: AnyObject {
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError>
    /// P3-41 QA: the pid of the application AX says has focus (system-wide `AXFocusedApplication`), nil = unknown.
    /// Identity only. A Ghostty-based terminal may name no focused element, but the focused app is still known.
    func focusedApplicationPID(timeout: Double) -> Int32?
}

extension FocusedElementProviding {
    /// P3-41 QA: a provider that can't tell (fakes) answers unknown.
    func focusedApplicationPID(timeout: Double) -> Int32? { nil }
}
