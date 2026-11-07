// P2-23: Launch at login, as Core sees it (R8 §8: `SMAppService.Status`, mirrored so Core doesn't import
// ServiceManagement).

import Foundation

enum LoginItemStatus: Sendable, Equatable {
    /// Kytkin opens at login.
    case enabled
    /// Registered, but the user still has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// Not registered (the default).
    case notRegistered
    /// macOS can't find the app's login item (also seen before the first register). Treated as off.
    case notFound

    /// What the "Open at login" switch shows: on once the user asked for it, even while approval is pending.
    var isOn: Bool { self == .enabled || self == .requiresApproval }
}
