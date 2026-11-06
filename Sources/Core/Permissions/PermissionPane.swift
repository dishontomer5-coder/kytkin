// P2-16: The System Settings panes Kytkin deep-links to (keyboard-event-tap.md §1, context-monitoring.md §3).
// Only opened from a user click (onboarding or the Permissions tab). Automation (per browser) is Phase 3.

import Foundation

// P2-16 QA: the legacy `com.apple.preference.security?Privacy_…` form works on macOS 14 through 26. Checked
// read-only on 26.6: the Privacy & Security extension (com.apple.settings.PrivacySecurity.extension) declares
// legacyBundleIdentifier com.apple.preference.security and allowsXAppleSystemPreferencesURLScheme, and its
// PrivacySecurity.searchTerms lists both anchors (Privacy_Accessibility, Privacy_ListenEvent). The newer id
// (com.apple.settings.PrivacySecurity.extension?Privacy_…) only exists from macOS 13, so the legacy one is kept.
enum PermissionPane: Sendable, Equatable, Hashable, CaseIterable {
    case accessibility
    case inputMonitoring

    /// System Settings, opened when a deep link can't be (SystemPermissionRequester).
    static let systemSettingsBundleID = "com.apple.systempreferences"

    /// Privacy & Security → the pane's list, where the user turns Kytkin on.
    var settingsURL: URL {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        }
    }
}
