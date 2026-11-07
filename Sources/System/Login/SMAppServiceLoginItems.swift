// P2-23: Launch at login through `SMAppService.mainApp` (R8 §8): no helper app, no entitlement, works unsandboxed.
// Thin adapter behind `LoginItemManaging`; no decisions. Never compiled into tests (tests use a fake), and
// `register`/`unregister`/`openSystemSettingsLoginItems` are reached only from the user's clicks in Settings → General.

import Foundation
import ServiceManagement

@MainActor final class SMAppServiceLoginItems: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
