// P2-16: What PermissionsManager publishes: the grants FeatureAvailability.compute takes, plus Secure Input
// and the "Quit & Reopen" hint (001 §6.1 step 4). A plain value; the composition root (P2-20) recomputes
// FeatureAvailability from it on every change.

import Foundation

struct PermissionStatus: Sendable, Equatable {
    /// `.unknown` until the first read. `automation` stays empty until Phase 3 (P3-7).
    var grants: PermissionGrants
    /// Secure Input is on right now (temporary; 001 §6.2 last row).
    var secureInput: Bool
    /// Input Monitoring was granted while Kytkin was running. A listen-only tap usually can't be created
    /// until Kytkin is relaunched (keyboard-event-tap.md §1), so the UI offers "Quit & Reopen".
    var inputMonitoringNeedsRelaunch: Bool

    init(grants: PermissionGrants = PermissionGrants(), secureInput: Bool = false,
         inputMonitoringNeedsRelaunch: Bool = false) {
        self.grants = grants
        self.secureInput = secureInput
        self.inputMonitoringNeedsRelaunch = inputMonitoringNeedsRelaunch
    }
}
