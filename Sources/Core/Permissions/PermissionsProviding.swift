// P2-16: What the composition root (P2-20), controllers and the Permissions UI (P2-26) use.
// System/Permissions/PermissionsManager implements it; controller tests use a fake.
//
// Contract:
//   - Reads are silent and never prompt. `onChange` fires only when `status` actually changes.
//   - `request…` and `openSystemSettings` show system UI, so they are called only from a user click.
//   - `setInteractive(true)` while the onboarding or Permissions screen is visible: poll every 1 s
//     (there is no system notification for grants, 001 §2.2). Set it back to false when the screen closes.
//     Otherwise a modest background poll runs (`PermissionMonitor.backgroundPollNanos`).
//   - P2-45: Secure Input is not part of this; KeyWatcher owns it (`KeyWatcherStatus.secureInputOn`, 001 §12.2 W5).

import Foundation

@MainActor protocol PermissionsProviding: AnyObject {
    var status: PermissionStatus { get }
    var onChange: (@MainActor (PermissionStatus) -> Void)? { get set }
    func start()
    func stop()
    /// Silent re-read now ("Check again").
    func refresh()
    func setInteractive(_ visible: Bool)
    func requestAccessibility()
    func requestInputMonitoring()
    func openSystemSettings(_ pane: PermissionPane)

    // P3-7: Automation per browser (001 §14.7).
    /// Silent checks (never a prompt), ≤ 1 per 5 s per browser. Results arrive later through `status`/`onChange`.
    func refreshAutomation(for bundleIDs: Set<String>)
    /// User click only: shows the macOS Automation prompt for `bundleID` if it was never answered.
    func requestAutomation(for bundleID: String)
    /// User click only: System Settings → Privacy & Security → Automation.
    func openAutomationSettings()
}
