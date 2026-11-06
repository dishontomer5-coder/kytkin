// P2-16: What the composition root (P2-20), controllers and the Permissions UI (P2-26) use.
// System/Permissions/PermissionsManager implements it; controller tests use a fake.
//
// Contract:
//   - Reads are silent and never prompt. `onChange` fires only when `status` actually changes.
//   - `request…` and `openSystemSettings` show system UI, so they are called only from a user click.
//   - `setInteractive(true)` while the onboarding or Permissions screen is visible: poll every 1 s
//     (there is no system notification for grants, 001 §2.2). Set it back to false when the screen closes.
//   - `setWatchesSecureInput(true)` while typing features are on: everything is re-read every 1 s, so
//     Secure Input is noticed quickly (001 §2.2 KeyWatcher "Secure Input"). Otherwise a modest background
//     poll runs (`PermissionMonitor.backgroundPollNanos`).

import Foundation

@MainActor protocol PermissionsProviding: AnyObject {
    var status: PermissionStatus { get }
    var onChange: (@MainActor (PermissionStatus) -> Void)? { get set }
    func start()
    func stop()
    /// Silent re-read now ("Check again").
    func refresh()
    func setInteractive(_ visible: Bool)
    func setWatchesSecureInput(_ on: Bool)
    func requestAccessibility()
    func requestInputMonitoring()
    func openSystemSettings(_ pane: PermissionPane)
}
