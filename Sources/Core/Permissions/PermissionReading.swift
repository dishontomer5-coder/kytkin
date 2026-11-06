// P2-16: One silent read of the system's permission state, exactly as the OS reports it (raw booleans).
// `PermissionMonitor` turns it into `PermissionStatus`. Filled by System/Permissions/SystemPermissionProbe
// from AXIsProcessTrusted() and CGPreflightListenEventAccess(); tests use fakes. P2-45: Secure Input is read by
// KeyWatcher only (001 §12.2 W5).

import Foundation

struct PermissionReading: Sendable, Equatable {
    /// AXIsProcessTrusted(): Accessibility granted (active tap, AX, posting keys).
    var accessibilityTrusted: Bool
    /// CGPreflightListenEventAccess(): Input Monitoring granted (listen-only tap).
    var inputMonitoringGranted: Bool

    init(accessibilityTrusted: Bool = false, inputMonitoringGranted: Bool = false) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringGranted = inputMonitoringGranted
    }
}
