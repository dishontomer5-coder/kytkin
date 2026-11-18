// P4-5b: the live `ChatFocusWalkNode` over one `AXUIElement` of a chat app's focused window. Read only: role and
// children in one `AXUIElementCopyMultipleAttributeValues` call, and `AXFocused` (asked only of text boxes). Never
// sets an attribute, never performs an action. Each read gets its own messaging timeout (≤ 0.25 s, ≤ what is left).
// Reads no text. Not compiled into the test target (it talks to real apps); the walk itself is Core's `ChatFocusWalk`.

import ApplicationServices

final class AXChatFocusNode: ChatFocusWalkNode {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    private static var roleAndChildrenNames: CFArray { [kAXRoleAttribute, kAXChildrenAttribute] as CFArray }

    func roleAndChildren(timeout: Double) -> ChatFocusNodeRead<AXChatFocusNode> {
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, Self.roleAndChildrenNames,
                                                           AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        if error == .cannotComplete { return .timedOut }
        guard error == .success, let list = values as? [AnyObject], list.count == 2 else { return .failed }
        // A missing attribute comes back as an AXValue holding an error: neither a string nor an array.
        let role = list[0] as? String
        let children = (list[1] as? [AXUIElement]) ?? []
        return .read(role: role, children: children.map(AXChatFocusNode.init))
    }

    func isFocused(timeout: Double) -> (focused: Bool?, timedOut: Bool) {
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &value)
        if error == .cannotComplete { return (nil, true) }
        guard error == .success, let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return (nil, false) }
        return (CFBooleanGetValue((value as! CFBoolean)), false)
    }
}
