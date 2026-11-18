// P2-18: The AX seam's entry point: the system-wide focused element, with the messaging timeout already set
// on it (001 §7 B5). Never prompts for Accessibility; without it, it answers `.notTrusted`.

import Foundation

protocol FocusedElementProviding: AnyObject {
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError>
    /// P3-41 QA: the pid of the application AX says has focus (system-wide `AXFocusedApplication`), nil = unknown.
    /// Identity only. A Ghostty-based terminal may name no focused element, but the focused app is still known.
    func focusedApplicationPID(timeout: Double) -> Int32?
    /// P4-5b: a chat app that names no focused element: walk its focused window (read only, ≤ `maxNodes` nodes,
    /// ≤ `budgetNanos` wall time) for the text box that says `AXFocused = true` (`ChatFocusWalk`).
    func chatFocusWalk(pid: Int32, maxNodes: Int, budgetNanos: UInt64) -> ChatFocusWalkResult
}

/// P4-5b: the walk's report and, when found, the box (with the messaging timeout set, as a focused element would be).
struct ChatFocusWalkResult {
    let report: ChatFocusWalkReport
    let element: (any AXTextElement)?

    static var unavailable: ChatFocusWalkResult { ChatFocusWalkResult(report: .unavailable, element: nil) }
}

extension FocusedElementProviding {
    /// P3-41 QA: a provider that can't tell (fakes) answers unknown.
    func focusedApplicationPID(timeout: Double) -> Int32? { nil }
    /// P4-5b: a provider that can't walk finds nothing.
    func chatFocusWalk(pid: Int32, maxNodes: Int, budgetNanos: UInt64) -> ChatFocusWalkResult { .unavailable }
}
