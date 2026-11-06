// P2-16: Why PermissionsManager is reading the permission state (001 §2.2 refresh triggers).

import Foundation

enum PermissionRefreshReason: Sendable, Equatable {
    /// `start()` (launch). Always reads.
    case launch
    /// Another app became frontmost. Bursts are coalesced (`PermissionMonitor.minEventGapNanos`).
    case appActivated
    /// Kytkin itself became active (the user came back from System Settings). Always reads.
    case kytkinActivated
    /// The poll timer. Always reads.
    case timer
    /// Right after a request button. Always reads.
    case afterRequest
    /// An explicit `refresh()` call (for example a "Check again" button). Always reads.
    case manual
}
