// P2-16: The System Settings panes Kytkin deep-links to (keyboard-event-tap.md §1, context-monitoring.md §3).
// Only opened from a user click (onboarding or the Permissions tab). Automation (per browser) is Phase 3.

import Foundation

enum PermissionPane: Sendable, Equatable, Hashable, CaseIterable {
    case accessibility
    case inputMonitoring

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
