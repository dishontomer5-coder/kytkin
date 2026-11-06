// P2-15: Tier-0 app activation feed (001 §2.2), implemented over NSWorkspace in System/Context.
// It only translates notifications; all filtering and dedupe happen in `ContextAssembler`.
// P2-15: 001 lists only `onActivate` + `start()`. `onTerminate` and `stop()` are added because tier 0
// also observes `didTerminate` (001 §2.2) and ContextMonitoring has a `stop()` (reported to the Architect).

import Foundation

@MainActor protocol AppActivationSource: AnyObject {
    /// (bundleID, pid) of the app that became frontmost. The bundle ID is "" when the app has none.
    /// Also called with the frontmost app on `start()` and after a Space change.
    var onActivate: (@MainActor (String, Int32) -> Void)? { get set }
    /// pid of an app that quit.
    var onTerminate: (@MainActor (Int32) -> Void)? { get set }
    func start()
    func stop()
}
