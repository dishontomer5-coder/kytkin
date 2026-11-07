// P2-52 item 1: a one-shot main-actor delay. AppController uses it to look at the frontmost app again shortly after
// Kytkin resigns, because `NSWorkspace.frontmostApplication` can still be Kytkin at that moment. The real one
// (`MainRunLoopOneShot`, App) is a main-run-loop Timer; tests use a fake driven by the FakeClock.

import Foundation

@MainActor protocol OneShotScheduling: AnyObject {
    /// Runs `handler` once after `afterNanos`, replacing anything already scheduled.
    func schedule(afterNanos: UInt64, _ handler: @escaping @MainActor () -> Void)
    func cancel()
}
