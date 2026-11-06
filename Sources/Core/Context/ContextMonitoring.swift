// P2-15: The contract SwitchController (P2-20) uses to hear about context changes (001 §2.2).
// System/Context/ContextMonitor implements it; controller tests use a fake.

import Foundation

@MainActor protocol ContextMonitoring: AnyObject {
    /// The last emitted Context; nil until an app other than Kytkin has been frontmost.
    var current: Context? { get }
    /// Called once per new Context (deduplicated and debounced by `ContextAssembler`).
    var onChange: (@MainActor (Context) -> Void)? { get set }
    func start()
    func stop()
}
