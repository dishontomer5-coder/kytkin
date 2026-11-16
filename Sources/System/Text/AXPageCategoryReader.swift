// P3-50: the live `TextReplacing.focusedPageCategory`: from the system-wide focused element, walk `AXParent` (≤ 40
// steps, every element with the 0.25 s messaging timeout; P3-50 QA: ≤ 300 ms in all) and read the `AXURL` of every
// `AXWebArea` on the way. The addresses go straight to `PageCategory.of(webAreaURLs:reachedTop:)` (any whole-document
// area wins; a walk that didn't reach the top is unknown); only the category leaves this function, the addresses and
// their hosts are dropped here (design.md: a browser address is reduced inside the one function that reads it). Reads
// no text box content. Never logs. Not compiled into the test target (tests can't reach real apps).

import ApplicationServices
import Dispatch

enum AXPageCategoryReader {
    static let maxParentSteps = 40
    /// P3-50 QA: the whole walk's wall-clock cap (each call alone may take up to the messaging timeout).
    static let maxWalkNanos: UInt64 = 300_000_000

    /// P3-53: `budgetNanos` caps the walk below `maxWalkNanos` (the convert's B5 budget), and no AX call is given more
    /// time than is left.
    static func focusedPageCategory(timeout: Double, budgetNanos: UInt64) -> PageCategory {
        guard AXIsProcessTrusted() else { return .unknown }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ min(maxWalkNanos, budgetNanos)
        func callTimeout() -> Float {
            let left = Double(deadline &- min(deadline, DispatchTime.now().uptimeNanoseconds)) / 1e9
            return Float(max(0.01, min(timeout, left)))
        }
        func late() -> Bool { DispatchTime.now().uptimeNanoseconds > deadline }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, callTimeout())
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        var element = unsafeDowncast(value, to: AXUIElement.self)
        var urls: [String?] = []   // innermost first; dropped on return
        var reachedTop = false
        for _ in 0..<maxParentSteps {   // bounded walk up
            if late() { return .unknown }
            AXUIElementSetMessagingTimeout(element, callTimeout())
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if roleError == .cannotComplete { return .unknown }   // a timeout: ask nothing more
            if roleError == .success, (role as? String) == "AXWebArea" {
                let (url, urlError) = address(of: element)
                if urlError == .cannotComplete { return .unknown }
                urls.append(url)
            }
            var parent: CFTypeRef?
            let parentError = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent)
            if parentError == .cannotComplete { return .unknown }
            guard parentError == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                reachedTop = true
                break
            }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        if late() { return .unknown }
        return PageCategory.of(webAreaURLs: urls, reachedTop: reachedTop)
    }

    /// One web area's `AXURL` as a string (nil = none / unreadable).
    private static func address(of webArea: AXUIElement) -> (String?, AXError) {
        var url: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &url)
        guard error == .success, let url else { return (nil, error) }
        if CFGetTypeID(url) == CFURLGetTypeID() { return ((unsafeDowncast(url, to: CFURL.self) as URL).absoluteString, .success) }
        if CFGetTypeID(url) == CFStringGetTypeID() { return (url as? String, .success) }
        return (nil, .success)
    }
}
