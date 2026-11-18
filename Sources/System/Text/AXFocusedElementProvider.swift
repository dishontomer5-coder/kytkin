// P2-18: The live `FocusedElementProviding`: the system-wide focused UI element (R5 §A), with the 0.25 s
// messaging timeout set on both the system-wide element and the focused one (001 §7 B5).
// `AXIsProcessTrusted()` is the silent check; this adapter never prompts for Accessibility.
// Not compiled into the test target: tests can't reach real apps.

import ApplicationServices

final class AXFocusedElementProvider: FocusedElementProviding {
    func focusedTextElement(timeout: Double) -> Result<any AXTextElement, AXAccessError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(timeout))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success else { return .failure(AXAccessError(error)) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .failure(.failed) }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, Float(timeout))
        return .success(AXUIElementTextElement(element))
    }

    /// P3-41 QA: the focused application's pid (identity only, no attribute values read from it).
    func focusedApplicationPID(timeout: Double) -> Int32? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(timeout))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success, pid > 0 else {
            return nil
        }
        return pid
    }

    /// P4-5b: a chat app that names no focused element: walk its `AXFocusedWindow` (read only) for the text box that
    /// says `AXFocused = true`. The found box gets the usual messaging timeout, as a focused element would.
    func chatFocusWalk(pid: Int32, maxNodes: Int, budgetNanos: UInt64) -> ChatFocusWalkResult {
        guard AXIsProcessTrusted(), budgetNanos > 0 else { return .unavailable }
        let clock = SystemClock()
        let start = clock.nowNanos
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(min(ChatFocusWalk.maxReadTimeout,
                                                      max(ChatFocusWalk.minReadTimeout, Double(budgetNanos) / 1e9))))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let used = clock.nowNanos &- start
        guard used < budgetNanos else { return .unavailable }
        let window = AXChatFocusNode(unsafeDowncast(value, to: AXUIElement.self))
        switch ChatFocusWalk.find(from: window, maxNodes: maxNodes, budgetNanos: budgetNanos - used, clock: clock) {
        case .found(let node, let stats):
            AXUIElementSetMessagingTimeout(node.element, Float(ChatFocusWalk.maxReadTimeout))   // the B5 0.25 s
            return ChatFocusWalkResult(report: .found(stats), element: AXUIElementTextElement(node.element))
        case .notFound(let stats):
            return ChatFocusWalkResult(report: .notFound(stats), element: nil)
        case .budget(let stats):
            return ChatFocusWalkResult(report: .budget(stats), element: nil)
        }
    }

    /// P6-0j: the pid of the app that owns the system-wide focused element (identity only, no attribute values read
    /// from it). Spotlight's panel owns the focus while another app stays frontmost.
    func focusedElementPID(timeout: Double) -> Int32? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(timeout))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success, pid > 0 else {
            return nil
        }
        return pid
    }
}
