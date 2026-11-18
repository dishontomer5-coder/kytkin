// P4-5b: the replacer's focus provider, with an optional pinned element: the chat composer a `ChatFocusWalk` found
// while the app named no focused element (Slack right after its AX tree was turned on). While pinned, for one convert:
//   - the system's focused element when it is a text box (a role in `ChatFocusWalk.boxRoles` + `AXComboBox`): that one
//     (it may be the pinned element itself; if it is another box, same-element checks fail, as they should);
//   - else (nothing focused, or a window / web view) the pinned element while it still says `AXFocused = true` and
//     focus is still in its app (P4-5b QA);
//   - else what the system said (nothing usable: the convert stops or just switches).
// So the clipboard's `focusIsSame` checks hold for the walked element exactly while it keeps focus. Unpinned at the end
// of every request. Read only; holds no text.

import Foundation

final class ChatFocusPin: FocusedElementProviding {
    private let base: any FocusedElementProviding
    private(set) var pinned: (any AXTextElement)?

    static let systemBoxRoles: Set<String> = ChatFocusWalk.boxRoles.union(["AXComboBox"])

    init(base: any FocusedElementProviding) {
        self.base = base
    }

    func pin(_ element: any AXTextElement) { pinned = element }
    func unpin() { pinned = nil }

    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError> {
        let system = base.focusedTextElement(timeout: timeout)
        guard let pinned else { return system }
        // P4-5b QA: the app didn't answer the focus read: ask it nothing more (another 0.25 s wait).
        if case .failure(.timeout) = system { return system }
        // P4-5b QA: a composer may keep saying `AXFocused = true` while its app is in the background (Chromium reports
        // focus within its own tree). So the pin stands in only while focus is in the pinned element's app: a focused
        // element or a focused application in another app wins (same-element checks fail, ⌘V is never posted there).
        guard let pinnedPID = pinned.processID else { return system }
        if case .success(let el) = system {
            if case .success(let role) = el.string(.role), Self.systemBoxRoles.contains(role) { return system }
            if let pid = el.processID, pid != pinnedPID { return system }
        }
        if let app = base.focusedApplicationPID(timeout: timeout), app != pinnedPID { return system }
        if case .success(true) = pinned.isFocused() { return .success(pinned) }
        return system
    }

    func focusedApplicationPID(timeout: Double) -> Int32? {
        base.focusedApplicationPID(timeout: timeout)
    }

    func chatFocusWalk(pid: Int32, maxNodes: Int, budgetNanos: UInt64) -> ChatFocusWalkResult {
        base.chatFocusWalk(pid: pid, maxNodes: maxNodes, budgetNanos: budgetNanos)
    }
}
