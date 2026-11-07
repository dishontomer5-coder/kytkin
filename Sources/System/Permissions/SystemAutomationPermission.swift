// P3-7: The silent Automation check (001 §14.7, R3 §1). `askUserIfNeeded` is always false here: this can never show
// a prompt. NEVER compiled into the test target (it asks TCC about real apps).
//
// The target is the running browser's pid (`NSAppleEventDescriptor(processIdentifier:)`), never its bundle ID, the
// same as the sends. No running instance → `.notRunning` without any call.
// Event pair: `core/getd`, the one event Kytkin sends, instead of the design's typeWildCard (QA note: macOS grants
// Automation per app pair, so the answer is the same; using the real pair keeps the silent check and the click's
// request identical, and avoids the reported case where a wildcard request returns -1744 without showing a prompt).

import AppKit
import CoreServices

struct SystemAutomationPermission: AutomationPermissionChecking {
    func check(bundleID: String) -> AutomationCheckResult {
        guard let pid = Self.runningPid(bundleID) else { return .notRunning }
        return AutomationCheckResult(status: Self.silentCheck(NSAppleEventDescriptor(processIdentifier: pid)))
    }

    /// `AEDeterminePermissionToAutomateTarget(target, core, getd, askUserIfNeeded: false)`. Also used by
    /// AppleEventAddressReader before every send.
    static func silentCheck(_ target: NSAppleEventDescriptor) -> OSStatus {
        determine(target, askUserIfNeeded: false)
    }

    /// The only place the system call is made. `askUserIfNeeded: true` is passed ONLY by SystemAutomationRequester.
    static func determine(_ target: NSAppleEventDescriptor, askUserIfNeeded: Bool) -> OSStatus {
        guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AppleEventObjectPath.code("core"),
                                                     AppleEventObjectPath.code("getd"), askUserIfNeeded)
    }

    /// The pid of a running, not terminated instance (never launches anything).
    static func runningPid(_ bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { !$0.isTerminated }?.processIdentifier
    }
}
