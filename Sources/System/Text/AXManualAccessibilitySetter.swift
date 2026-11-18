// P4-5: the live `ManualAccessibilitySetting`: `AXManualAccessibility = kCFBooleanTrue` on the application element of a
// chat app (Electron's switch for assistive apps), with the given messaging timeout. Never `AXEnhancedUserInterface`
// (window-manager side effects, R5), never on browsers (R3b rule 1): `ChatAccessibilityEnabler` only calls it for
// `ReplacementCapabilities.chatAppBundleIDs`. Reads and sends no text. Never prompts (`AXIsProcessTrusted()` is the
// silent check). Not compiled into the test target: tests never write to real apps.

import ApplicationServices

final class AXManualAccessibilitySetter: ManualAccessibilitySetting, Sendable {
    static let attribute = "AXManualAccessibility"

    func setManualAccessibility(pid: Int32, timeout: Double) -> ManualAccessibilityAnswer {
        guard AXIsProcessTrusted() else { return .notTrusted }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        switch AXUIElementSetAttributeValue(app, Self.attribute as CFString, kCFBooleanTrue) {
        case .success: return .set
        case .cannotComplete: return .noAnswer
        case .apiDisabled: return .notTrusted
        default: return .refused
        }
    }
}
