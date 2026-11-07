// P2-26: A PermissionsProviding fake that records every call, so tests can prove the request APIs and System
// Settings are reached only from the explicit user-click methods. Nothing here touches TCC or System Settings.

import Foundation

@MainActor final class RecordingPermissions: PermissionsProviding {
    enum Call: Equatable {
        case start, stop, refresh, setInteractive(Bool)
        case requestAccessibility, requestInputMonitoring, openSystemSettings(PermissionPane)
        case refreshAutomation(Set<String>), requestAutomation(String), openAutomationSettings
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
    func refreshAutomation(for bundleIDs: Set<String>) { calls.append(.refreshAutomation(bundleIDs)) }
    func requestAutomation(for bundleID: String) { calls.append(.requestAutomation(bundleID)) }
    func openAutomationSettings() { calls.append(.openAutomationSettings) }

    /// Calls that show system UI (a permission dialog or System Settings).
    var promptingCalls: [Call] {
        calls.filter {
            switch $0 {
            case .requestAccessibility, .requestInputMonitoring, .openSystemSettings, .requestAutomation,
                 .openAutomationSettings: true
            default: false
            }
        }
    }

    var interactiveCalls: [Bool] {
        calls.compactMap { if case .setInteractive(let v) = $0 { v } else { nil } }
    }

    /// P3-7: a browser's Automation state, as a silent check would publish it.
    func set(automation bundleID: String, _ state: PermissionState?) {
        status.grants.automation[bundleID] = state
        onChange?(status)
    }

    func set(accessibility: PermissionState, inputMonitoring: PermissionState = .notDetermined,
             needsRelaunch: Bool = false) {
        status = PermissionStatus(grants: PermissionGrants(accessibility: accessibility, inputMonitoring: inputMonitoring),
                                  inputMonitoringNeedsRelaunch: needsRelaunch)
        onChange?(status)
    }
}
