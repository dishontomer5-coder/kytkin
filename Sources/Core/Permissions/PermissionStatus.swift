// P2-16: What PermissionsManager publishes: the grants FeatureAvailability.compute takes, plus the
// "Quit & Reopen" hint (001 §6.1 step 4). A plain value; the composition root (P2-20) recomputes
// FeatureAvailability from it on every change. P2-45: no Secure Input here; that comes from
// `KeyWatcherStatus.secureInputOn` (001 §12.2 W5).

import Foundation

struct PermissionStatus: Sendable, Equatable {
    /// `.unknown` until the first read. `automation` stays empty until Phase 3 (P3-7).
    var grants: PermissionGrants
    /// Input Monitoring was granted while Kytkin was running. A listen-only tap usually can't be created
    /// until Kytkin is relaunched (keyboard-event-tap.md §1), so the UI offers "Quit & Reopen".
    var inputMonitoringNeedsRelaunch: Bool

    init(grants: PermissionGrants = PermissionGrants(), inputMonitoringNeedsRelaunch: Bool = false) {
        self.grants = grants
        self.inputMonitoringNeedsRelaunch = inputMonitoringNeedsRelaunch
    }
}
