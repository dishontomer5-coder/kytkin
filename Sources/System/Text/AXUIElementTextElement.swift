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
    /// levels; each element gets the same messaging timeout as this one; P3-44 QA: ≤ 300 ms in all, else `.timeout`;
    /// P3-53: and never past the shared deadline of `inlineAtoms`).
    /// Kept: an element whose role is `AXLink`, or whose own text (`AXValue`, else `AXTitle`, else `AXDescription`)
    /// starts with `@` or `#`; 2–64 UTF-16 units, no line break.
    /// P3-46 (owner retest: `@Tomer Dishon`'s second word converted): an element below the box's paragraphs (depth ≥ 2)
    /// with no text of its own whose direct `AXStaticText` children (≤ 8) together read `@…` / `#…` is kept as one atom,
    /// so a pill whose name is split over text runs stays whole. Never logs; the texts go straight to the convert's plan
    /// (the role names may go to the DEBUG trace).
    /// P3-48: plus every text of a Gmail quoted thread / signature / extra or a blockquote (`quoteAtoms`).
    func inlineAtoms(maxNodes: Int, budgetNanos: UInt64) -> Result<[InlineAtom], AXAccessError> {
        // P3-48 QA: one wall clock for both walks. P3-53: that clock is what is left of the convert's read budget
        // (`budgetNanos`, from `ChromiumAXConvert`, inside the B5 400 ms), never more than 500 ms.
        let deadline = DispatchTime.now().uptimeNanoseconds &+ min(500_000_000, budgetNanos)
        switch pillAtoms(maxNodes: maxNodes, deadline: deadline) {
        case .failure(let e): return .failure(e)
        case .success(let pills):
            return quoteAtoms(deadline: deadline).map { pills + $0 }
        }
    }

    /// P3-48 (Coordinator 2026-11-16): a whole-box convert of a Gmail reply never converts the quoted thread or the
    /// signature. Breadth-first over the box's elements to depth 3 (≤ 300 elements) for a container whose
    /// `AXDOMClassList` names `gmail_quote`, `gmail_signature` or `gmail_extra`, or whose `AXBlockQuoteLevel` is above 0;
    /// then, depth-first inside each (≤ 1,500 elements, ≤ 40 levels), the `AXValue` of every `AXStaticText`, trimmed,
    /// as an atom (role `AXQuoteText`): `BoxConversion` never converts them and they never decide the direction. A
    /// container found but not walked to its end (budget, the shared wall clock of `inlineAtoms`) → `.timeout`: the Chromium
    /// convert stops before typing (the caller falls back), rather than convert a part of the quote it couldn't see.
    /// Not finding a container within the search budget is not an error (an ordinary long box). Never logs.
    private func quoteAtoms(deadline: UInt64) -> Result<[InlineAtom], AXAccessError> {
        // P3-53: no single call is given more than what is left of the shared deadline (≥ 10 ms).
        let timeout = Self.callTimeout(until: deadline)
        func children(_ e: AXUIElement) -> (list: [AXUIElement], timedOut: Bool) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value)
            if error == .cannotComplete { return ([], true) }
            let list = (value as? [AXUIElement]) ?? []
            for c in list { AXUIElementSetMessagingTimeout(c, timeout) }
            return (list, false)
        }
        func string(_ e: AXUIElement, _ attribute: String) -> (String?, Bool) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
            if error == .cannotComplete { return (nil, true) }
            guard error == .success, let value, CFGetTypeID(value) == CFStringGetTypeID() else { return (nil, false) }
            return ((value as! String), false)
        }
        func isQuoteContainer(_ e: AXUIElement) -> (Bool, Bool) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(e, "AXDOMClassList" as CFString, &value)
            if error == .cannotComplete { return (false, true) }
            if let classes = value as? [String],
               classes.contains(where: { c in ["gmail_quote", "gmail_signature", "gmail_extra"].contains { c.contains($0) } }) {
                return (true, false)
            }
            var level: CFTypeRef?
            let levelError = AXUIElementCopyAttributeValue(e, "AXBlockQuoteLevel" as CFString, &level)
            if levelError == .cannotComplete { return (false, true) }
            if let n = level as? NSNumber, n.intValue > 0 { return (true, false) }
            return (false, false)
        }
        // 1. Find the containers (bounded search; not finding one is fine).
        var containers: [AXUIElement] = []
        let top = children(element)
        if top.timedOut { return .failure(.timeout) }
        var queue: [(AXUIElement, Int)] = top.list.prefix(300).map { ($0, 1) }
        var i = 0
        while i < queue.count, i < 300 {   // bounded
            // P3-48 QA: out of time while *searching* = nothing found further (as the doc says: not an error; stopping
            // every convert of a long box would be a regression). A container found is still walked completely.
            if DispatchTime.now().uptimeNanoseconds > deadline { break }
            let (e, depth) = queue[i]
            i += 1
            let (role, roleTimedOut) = string(e, kAXRoleAttribute)
            if roleTimedOut { return .failure(.timeout) }
            if role == kAXStaticTextRole { continue }
            let (isQuote, quoteTimedOut) = isQuoteContainer(e)
            if quoteTimedOut { return .failure(.timeout) }
            if isQuote { containers.append(e); continue }
            if depth < 3 {
                let next = children(e)
                if next.timedOut { return .failure(.timeout) }
                queue += next.list.prefix(max(0, 300 - queue.count)).map { ($0, depth + 1) }
            }
        }
        guard !containers.isEmpty else { return .success([]) }
        // 2. Every text inside them (complete, or the convert stops).
        var atoms: [InlineAtom] = []
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) -> Bool {   // false = budget / timeout: incomplete
            visited += 1
            guard visited <= 1_500, depth <= 40, DispatchTime.now().uptimeNanoseconds <= deadline else { return false }
            let (role, roleTimedOut) = string(e, kAXRoleAttribute)
            if roleTimedOut { return false }
            if role == kAXStaticTextRole {
                let (v, t) = string(e, kAXValueAttribute)
                if t { return false }
                if let v {
                    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 2 { atoms.append(InlineAtom(text: trimmed, role: "AXQuoteText")) }
                }
                return true
            }
            let next = children(e)
            if next.timedOut { return false }
            for c in next.list where !walk(c, depth: depth + 1) { return false }
            return true
        }
        for c in containers where !walk(c, depth: 1) { return .failure(.timeout) }
        return .success(atoms)
    }

    private func pillAtoms(maxNodes: Int, deadline shared: UInt64) -> Result<[InlineAtom], AXAccessError> {
        let timeout = Self.callTimeout(until: shared)   // ≤ the provider's 0.25 s (B5), ≤ what is left (P3-53)
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
        let deadline = min(shared, DispatchTime.now().uptimeNanoseconds &+ 300_000_000)
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

    /// P3-53: a messaging timeout for one AX call: the provider's 0.25 s, or what is left until `deadline` if less
    /// (never below 10 ms).
    static func callTimeout(until deadline: UInt64) -> Float {
        let now = DispatchTime.now().uptimeNanoseconds
        let left = Double(deadline > now ? deadline - now : 0) / 1e9
        return Float(max(0.01, min(0.25, left)))
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
