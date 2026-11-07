// P2-26: A PermissionsProviding fake that records every call, so tests can prove the request APIs and System
// Settings are reached only from the explicit user-click methods. Nothing here touches TCC or System Settings.

import Foundation

@MainActor final class RecordingPermissions: PermissionsProviding {
    enum Call: Equatable {
        case start, stop, refresh, setInteractive(Bool)
        case requestAccessibility, requestInputMonitoring, openSystemSettings(PermissionPane)
    }

    var status = PermissionStatus()
    var onChange: (@MainActor (PermissionStatus) -> Void)?
    private(set) var calls: [Call] = []

    func start() { calls.append(.start) }
    func stop() { calls.append(.stop) }
    func refresh() { calls.append(.refresh) }
    func setInteractive(_ visible: Bool) { calls.append(.setInteractive(visible)) }
    func requestAccessibility() { calls.append(.requestAccessibility) }
    func requestInputMonitoring() { calls.append(.requestInputMonitoring) }
    func openSystemSettings(_ pane: PermissionPane) { calls.append(.openSystemSettings(pane)) }

    /// Calls that show system UI (a permission dialog or System Settings).
    var promptingCalls: [Call] {
        calls.filter {
            switch $0 {
            case .requestAccessibility, .requestInputMonitoring, .openSystemSettings: true
            default: false
            }
        }
    }

    var interactiveCalls: [Bool] {
        calls.compactMap { if case .setInteractive(let v) = $0 { v } else { nil } }
    }

    func set(accessibility: PermissionState, inputMonitoring: PermissionState = .notDetermined,
             needsRelaunch: Bool = false) {
        status = PermissionStatus(grants: PermissionGrants(accessibility: accessibility, inputMonitoring: inputMonitoring),
                                  inputMonitoringNeedsRelaunch: needsRelaunch)
        onChange?(status)
    }
}
