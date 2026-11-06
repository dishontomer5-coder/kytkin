// P2-16: The real `PermissionRequesting`. Each method shows system UI, so it is called only from a user click
// (onboarding / Permissions tab, P2-26), through PermissionsManager. Deliberately NOT compiled into the test
// target (project.yml lists System files one by one), so no test can ever reach a prompt.
//   - Accessibility: AXIsProcessTrustedWithOptions(prompt: true). The dialog appears once; later calls only answer.
//   - Input Monitoring: CGRequestListenEventAccess(). Same: once, then it only answers.
//   - Deep links: x-apple.systempreferences:… (PermissionPane.settingsURL), opened with NSWorkspace.

import AppKit
import ApplicationServices
import CoreGraphics

@MainActor final class SystemPermissionRequester: PermissionRequesting {
    /// The value of `kAXTrustedCheckOptionPrompt`. Spelled out because the imported global is a mutable
    /// C var, which Swift 6 strict concurrency won't read from here.
    private static let axPromptKey = "AXTrustedCheckOptionPrompt"

    func requestAccessibility() {
        let options = [Self.axPromptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    func openSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
