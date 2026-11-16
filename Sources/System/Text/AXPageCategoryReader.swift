// P3-50: the live `TextReplacing.focusedPageCategory`: from the system-wide focused element, walk `AXParent` (≤ 40
// steps, every element with the 0.25 s messaging timeout) and keep the outermost `AXWebArea` seen (Gmail's compose box
// sits deep in the page; an editor's iframe is inside the page whose address matters). Its `AXURL` goes straight to
// `PageCategory.of(url:)`; only the category leaves this function, the address and its host are dropped here
// (design.md: a browser address is reduced inside the one function that reads it). Reads no text box content.
// Never logs. Not compiled into the test target (tests can't reach real apps).

import ApplicationServices

enum AXPageCategoryReader {
    static let maxParentSteps = 40

    static func focusedPageCategory(timeout: Double) -> PageCategory {
        guard AXIsProcessTrusted() else { return .unknown }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(timeout))
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        var element = unsafeDowncast(value, to: AXUIElement.self)
        var outermostWebArea: AXUIElement?
        for _ in 0..<maxParentSteps {   // bounded walk up
            AXUIElementSetMessagingTimeout(element, Float(timeout))
            var role: CFTypeRef?
            let roleError = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if roleError == .cannotComplete { return .unknown }   // a timeout: ask nothing more
            if roleError == .success, (role as? String) == "AXWebArea" { outermostWebArea = element }
            var parent: CFTypeRef?
            let parentError = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent)
            if parentError == .cannotComplete { return .unknown }
            guard parentError == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        guard let webArea = outermostWebArea else { return .unknown }
        var url: CFTypeRef?
        guard AXUIElementCopyAttributeValue(webArea, kAXURLAttribute as CFString, &url) == .success, let url else {
            return .unknown
        }
        if CFGetTypeID(url) == CFURLGetTypeID() {
            return PageCategory.of(url: (unsafeDowncast(url, to: CFURL.self) as URL).absoluteString)
        }
        if CFGetTypeID(url) == CFStringGetTypeID() { return PageCategory.of(url: url as! String) }
        return .unknown
    }
}
