// P3-10: The live `AXNodeReading` over `AXUIElement` (001 §14.3.2). Translation only: the read logic is pure Core.
// - Every element it hands out gets a 0.25 s messaging timeout before its first query: the app element at creation,
//   and each focused element, window, parent and child as it is obtained. A hung browser costs ≤ 0.25 s per call,
//   and the read's latch stops at the first timeout or after 0.5 s wall (B13).
// - `kAXErrorCannotComplete` (a timeout) → `.timedOut`; a missing or unsupported attribute → nil.
// - Read-only: only `AXUIElementCopyAttributeValue`. It never sets an attribute and never performs an action:
//   never `AXEnhancedUserInterface`, never `AXManualAccessibility` (R3b rule 1: nothing is ever set on a browser;
//   `AXEnhancedUserInterface` breaks window managers, R5). P4-5: the one exception anywhere in Kytkin is
//   `AXManualAccessibility = true` on the application element of a chat app (Slack, Discord, Teams:
//   `ReplacementCapabilities.chatAppBundleIDs`), set by `System/Text/AXManualAccessibilitySetter`, never by this reader
//   and never on a browser.
// - `url(of:)` returns AXURL's absoluteString; the reader hands it to `SiteReader` in the same expression.
// Never compiled into the tests (it talks to real apps). AX thread only. Never logs (lint rule 2b).

import ApplicationServices
import Foundation

struct AXElementTree: AXNodeReading {
    typealias Node = AXUIElement

    /// R2/R3b: long enough for a busy browser, short enough that a hung one can't stall the AX thread.
    static let messagingTimeout: Float = 0.25

    let app: AXUIElement

    init(pid: Int32) {
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
    }

    func focusedElement() throws(AXReadError) -> AXUIElement? {
        element(try copy(app, "AXFocusedUIElement"))
    }

    func mainWindow() throws(AXReadError) -> AXUIElement? {
        element(try copy(app, "AXMainWindow"))
    }

    func focusedWindow() throws(AXReadError) -> AXUIElement? {
        element(try copy(app, "AXFocusedWindow"))
    }

    func parent(of n: AXUIElement) throws(AXReadError) -> AXUIElement? {
        element(try copy(n, "AXParent"))
    }

    func children(of n: AXUIElement) throws(AXReadError) -> [AXUIElement] {
        guard let value = try copy(n, "AXChildren"), CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray   // type checked above
        var result: [AXUIElement] = []
        result.reserveCapacity(CFArrayGetCount(array))
        for i in 0..<CFArrayGetCount(array) {
            let raw = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: CFTypeRef.self)
            if let e = element(raw) { result.append(e) }
        }
        return result
    }

    func string(_ a: AXStringAttribute, of n: AXUIElement) throws(AXReadError) -> String? {
        guard let value = try copy(n, Self.name(of: a)), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    /// P3-31: e.g. AXDOMClassList. Only the string items of a CFArray are kept.
    func strings(_ a: AXStringListAttribute, of n: AXUIElement) throws(AXReadError) -> [String]? {
        guard let value = try copy(n, Self.name(of: a)), CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = value as! CFArray   // type checked above
        var result: [String] = []
        for i in 0..<CFArrayGetCount(array) {
            let raw = unsafeBitCast(CFArrayGetValueAtIndex(array, i), to: CFTypeRef.self)
            if CFGetTypeID(raw) == CFStringGetTypeID(), let s = raw as? String { result.append(s) }
        }
        return result
    }

    func url(of n: AXUIElement) throws(AXReadError) -> String? {
        guard let value = try copy(n, "AXURL") else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! URL).absoluteString   // CFURL toll-free bridges to URL
        }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        return nil
    }

    func isFocused(_ n: AXUIElement) throws(AXReadError) -> Bool? {
        guard let value = try copy(n, "AXFocused"), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    func area(of n: AXUIElement) throws(AXReadError) -> Double? {
        guard let value = try copy(n, "AXSize"), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
        return Double(size.width * size.height)
    }

    func isSame(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        CFEqual(a, b)
    }

    // MARK: - Internals

    private static func name(of a: AXStringAttribute) -> String {
        switch a {
        case .role: "AXRole"
        case .subrole: "AXSubrole"
        case .domIdentifier: "AXDOMIdentifier"
        case .identifier: "AXIdentifier"
        case .description: "AXDescription"
        case .title: "AXTitle"
        case .value: "AXValue"
        }
    }

    private static func name(of a: AXStringListAttribute) -> String {
        switch a {
        case .domClassList: "AXDOMClassList"
        }
    }

    /// The one AX read call. nil = the attribute has no value or isn't supported by this element.
    private func copy(_ e: AXUIElement, _ attribute: String) throws(AXReadError) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
        switch error {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw AXReadError(error)
        }
    }

    /// An element handed out by this tree: checked, and given the messaging timeout before its first query.
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let e = value as! AXUIElement   // type checked above
        AXUIElementSetMessagingTimeout(e, Self.messagingTimeout)
        return e
    }
}
