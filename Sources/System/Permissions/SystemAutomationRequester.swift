// P3-7: The ONE place Kytkin asks for Automation (`askUserIfNeeded: true`, 001 §14.7). macOS shows its prompt
// ("Kytkin wants access to control Google Chrome…") once, if the user never answered; later calls only answer.
// Reached only from a user click (Settings: the browser's Automation toggle turned on, or "Ask"), through
// PermissionsManager.requestAutomation, which runs it off main (it blocks until the user answers).
// NEVER compiled into the test target. Never launches the browser: no running instance → `.notRunning`, no call.

import AppKit

struct SystemAutomationRequester: AutomationPermissionRequesting {
    func ask(bundleID: String) -> AutomationCheckResult {
        guard let pid = SystemAutomationPermission.runningPid(bundleID) else { return .notRunning }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        return AutomationCheckResult(status: SystemAutomationPermission.determine(target, askUserIfNeeded: true))
    }
}
