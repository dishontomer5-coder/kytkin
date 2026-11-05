// P2-13: The grants FeatureAvailability decides from (001 §6). A plain value so Core never asks the system.

import Foundation

struct PermissionGrants: Sendable, Equatable {
    /// The main grant: active tap, AX reads/writes, posting keys (F2).
    var accessibility: PermissionState
    /// Fallback: a listen-only tap (R4).
    var inputMonitoring: PermissionState
    /// Apple Events per browser bundle ID (P3, opt-in).
    var automation: [String: PermissionState]

    init(accessibility: PermissionState = .unknown, inputMonitoring: PermissionState = .unknown,
         automation: [String: PermissionState] = [:]) {
        self.accessibility = accessibility
        self.inputMonitoring = inputMonitoring
        self.automation = automation
    }
}
