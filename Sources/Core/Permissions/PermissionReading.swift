// P2-16: One silent read of the system's permission state, exactly as the OS reports it (raw booleans).
// `PermissionMonitor` turns it into `PermissionStatus`. Filled by System/Permissions/SystemPermissionProbe
// from AXIsProcessTrusted(), CGPreflightListenEventAccess() and IsSecureEventInputEnabled(); tests use fakes.

import Foundation

struct PermissionReading: Sendable, Equatable {
    /// AXIsProcessTrusted(): Accessibility granted (active tap, AX, posting keys).
    var accessibilityTrusted: Bool
    /// CGPreflightListenEventAccess(): Input Monitoring granted (listen-only tap).
    var inputMonitoringGranted: Bool
    /// IsSecureEventInputEnabled(): some app (often a password field) is hiding key events right now.
    var secureInput: Bool

    init(accessibilityTrusted: Bool = false, inputMonitoringGranted: Bool = false, secureInput: Bool = false) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.secureInput = secureInput
    }
}
