// P2-18: The live `AXTextElement` over one `AXUIElement` (R5 §A). Translation only: every decision is in
// Core's `ReplacementExecutor`. The provider already set the 0.25 s messaging timeout on the element.
// Used only on @TextActor. Never logs; text read here goes straight back to the executor.
// Not compiled into the test target: tests can't reach real apps.

import ApplicationServices
import Dispatch

final class AXUIElementTextElement: AXTextElement {
    private let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    // MARK: Reading

    func string(_ attribute: AXTextAttribute) -> Result<String, AXAccessError> {
        if attribute == .webKitMarkedText { return webKitMarkedText() }
        return copy(attribute).flatMap { v in
            CFGetTypeID(v) == CFStringGetTypeID() ? .success(v as! String) : .failure(.failed)
        }
    }

    func integer(_ attribute: AXTextAttribute) -> Result<Int, AXAccessError> {
        copy(attribute).flatMap { v in
            CFGetTypeID(v) == CFNumberGetTypeID() ? .success((v as! NSNumber).intValue) : .failure(.failed)
        }
    }

    func range(_ attribute: AXTextAttribute) -> Result<TextRange, AXAccessError> {
        copy(attribute).flatMap(Self.textRange)
    }

    func isSettable(_ attribute: AXTextAttribute) -> Result<Bool, AXAccessError> {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute.rawValue as CFString, &settable)
        return error == .success ? .success(settable.boolValue) : .failure(AXAccessError(error))
    }

    func string(in range: TextRange) -> Result<String, AXAccessError> {
        guard let parameter = Self.axValue(range) else { return .failure(.failed) }
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard error == .success else { return .failure(AXAccessError(error)) }
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return .failure(.failed) }
        return .success(value as! String)
    }

    func supportsStringForRange() -> Result<Bool, AXAccessError> {
        var names: CFArray?
        let error = AXUIElementCopyParameterizedAttributeNames(element, &names)
        guard error == .success else { return .failure(AXAccessError(error)) }
        let list = (names as? [String]) ?? []
        return .success(list.contains(kAXStringForRangeParameterizedAttribute))
    }

    /// P3-42: attribute names only (no values), to tell web content from a native field.
    func attributeNames() -> Result<[String], AXAccessError> {
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)
        guard error == .success else { return .failure(AXAccessError(error)) }
        return .success((names as? [String]) ?? [])
    }

    /// P3-44: mention pills and links inside the box (breadth-first over `AXChildren`, ≤ `maxNodes` elements, ≤ 4
    /// levels; each element gets the same messaging timeout as this one; P3-44 QA: ≤ 300 ms in all, else `.timeout`).
    /// Kept: an element whose role is `AXLink`, or whose own text (`AXValue`, else `AXTitle`, else `AXDescription`)
    /// starts with `@` or `#`; 2–64 UTF-16 units, no line break.
    /// P3-46 (owner retest: `@Tomer Dishon`'s second word converted): an element below the box's paragraphs (depth ≥ 2)
    /// with no text of its own whose direct `AXStaticText` children (≤ 8) together read `@…` / `#…` is kept as one atom,
    /// so a pill whose name is split over text runs stays whole. Never logs; the texts go straight to the convert's plan
    /// (the role names may go to the DEBUG trace).
    func inlineAtoms(maxNodes: Int) -> Result<[InlineAtom], AXAccessError> {
        let timeout: Float = 0.25   // ReplacementExecutor.axTimeout, the per-element timeout the provider sets (B5)
        struct Node {
            let element: AXUIElement
            let depth: Int
            let parent: Int?
            var role: String?
            var own: String?
        }
        var nodes: [Node] = []
        func enqueueChildren(of e: AXUIElement, depth: Int, parent: Int?) -> AXError {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value)
            guard error == .success, let list = value as? [AXUIElement] else {
                return error == .cannotComplete ? error : .success
            }
            for child in list where nodes.count < maxNodes {
                AXUIElementSetMessagingTimeout(child, timeout)
                nodes.append(Node(element: child, depth: depth, parent: parent))
            }
            return .success
        }
        func text(of e: AXUIElement, _ attribute: String) -> (String?, AXError) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
            guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return (nil, error) }
            return (value as! String, .success)
        }
        func isAtomText(_ t: String) -> Bool {
            (2...64).contains(t.utf16.count) && !t.contains(where: \.isNewline)
        }
        if enqueueChildren(of: element, depth: 1, parent: nil) == .cannotComplete { return .failure(.timeout) }
        var atoms: [InlineAtom] = []
        var i = 0
        // P3-44 QA: a wall-clock cap too (each call may take up to the 0.25 s timeout without failing: ≤ 5 calls × 64
        // elements could hold the AX thread for many seconds). Past it the walk counts as a timeout: the convert stops
        // rather than run without the pills it may have missed.
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 300_000_000
        while i < nodes.count {   // bounded: the list never grows past maxNodes
            if DispatchTime.now().uptimeNanoseconds > deadline { return .failure(.timeout) }
            let e = nodes[i].element
            let (role, roleError) = text(of: e, kAXRoleAttribute)
            if roleError == .cannotComplete { return .failure(.timeout) }
            var own: String?
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                let (t, error) = text(of: e, attribute)
                if error == .cannotComplete { return .failure(.timeout) }
                if let t, !t.isEmpty { own = t; break }
            }
            nodes[i].role = role
            nodes[i].own = own
            if let own, isAtomText(own), role == "AXLink" || own.hasPrefix("@") || own.hasPrefix("#") {
                atoms.append(InlineAtom(text: own, role: role ?? "unknown"))
            }
            let depth = nodes[i].depth
            if depth < 4, enqueueChildren(of: e, depth: depth + 1, parent: i) == .cannotComplete {
                return .failure(.timeout)
            }
            i += 1
        }
        // P3-46: a pill container (no text of its own, below a paragraph) whose static-text children read `@…` / `#…`.
        for (index, node) in nodes.enumerated() where node.depth >= 2 && node.own == nil && node.role != "AXStaticText" {
            let children = nodes.filter { $0.parent == index }
            guard !children.isEmpty, children.count <= 8,
                  children.allSatisfy({ $0.role == "AXStaticText" }) else { continue }
            let joined = children.compactMap(\.own).joined()
            if isAtomText(joined), joined.hasPrefix("@") || joined.hasPrefix("#"),
               !atoms.contains(where: { $0.text == joined }) {
                atoms.append(InlineAtom(text: joined, role: node.role ?? "unknown"))
            }
        }
        return .success(atoms)
    }

    // MARK: Writing

    func setString(_ value: String, for attribute: AXTextAttribute) -> Result<Void, AXAccessError> {
        let error = AXUIElementSetAttributeValue(element, attribute.rawValue as CFString, value as CFString)
        return error == .success ? .success(()) : .failure(AXAccessError(error))
    }

    func setRange(_ value: TextRange, for attribute: AXTextAttribute) -> Result<Void, AXAccessError> {
        guard let axValue = Self.axValue(value) else { return .failure(.failed) }
        let error = AXUIElementSetAttributeValue(element, attribute.rawValue as CFString, axValue)
        return error == .success ? .success(()) : .failure(AXAccessError(error))
    }

    // MARK: Identity (P2-59c; same-element checks)

    var processID: Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func isSameElement(as other: any FocusedElementIdentity) -> Bool {
        guard let other = other as? AXUIElementTextElement else { return false }
        return CFEqual(element, other.element)
    }

    // MARK: Helpers

    private func copy(_ attribute: AXTextAttribute) -> Result<CFTypeRef, AXAccessError> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        guard error == .success else { return .failure(AXAccessError(error)) }
        guard let value else { return .failure(.noValue) }
        return .success(value)
    }

    /// R5: WebKit exposes composition as an opaque text-marker range. Present → ask WebKit for its text.
    /// If the text can't be read, report `.failed` so Core treats it as composing (can't be ruled out).
    private func webKitMarkedText() -> Result<String, AXAccessError> {
        switch copy(.webKitMarkedText) {
        case .failure(let e): return .failure(e)
        case .success(let markerRange):
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                element, "AXStringForTextMarkerRange" as CFString, markerRange, &value)
            if error == .cannotComplete { return .failure(.timeout) }
            guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else {
                return .failure(.failed)
            }
            return .success(value as! String)
        }
    }

    private static func textRange(_ value: CFTypeRef) -> Result<TextRange, AXAccessError> {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return .failure(.failed) }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else {
            return .failure(.failed)
        }
        return .success(TextRange(location: range.location, length: range.length))
    }

    private static func axValue(_ range: TextRange) -> AXValue? {
        var r = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &r)
    }
}
