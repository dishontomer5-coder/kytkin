// P2-16: The OS seam for the actions that show system UI. Every method may be called **only** from a user
// click (design.md: never prompt without a click). The real one is System/Permissions/SystemPermissionRequester,
// which is never compiled into the test target; tests use a recording fake.

import Foundation

@MainActor protocol PermissionRequesting: AnyObject {
    /// AXIsProcessTrustedWithOptions with the prompt option. The system shows its dialog at most once.
    func requestAccessibility()
    /// CGRequestListenEventAccess(). The system shows its dialog at most once.
    func requestInputMonitoring()
    /// Opens a System Settings deep link (`PermissionPane.settingsURL`).
    func openSettings(_ url: URL)
}
