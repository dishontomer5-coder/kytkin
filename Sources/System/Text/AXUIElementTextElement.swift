// P2-18: The live `AXTextElement` over one `AXUIElement` (R5 §A). Translation only: every decision is in
// Core's `ReplacementExecutor`. The provider already set the 0.25 s messaging timeout on the element.
// Used only on @TextActor. Never logs; text read here goes straight back to the executor.
// Not compiled into the test target: tests can't reach real apps.

import ApplicationServices

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

    // MARK: Identity (P2-59c, the undo record's same-element check)

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
