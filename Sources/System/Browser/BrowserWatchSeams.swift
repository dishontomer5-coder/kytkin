// P3-10: The two AX-thread seams under `BrowserWatchEngine` (001 §14.3.4), so the engine is unit-tested with a fake
// observer and a fake timer on a fake clock. The live ones are `FrontmostObserver` (never compiled into tests) and
// `RunLoopDeadlineTimer`. AX thread only.

/// The one `AXObserver`, on the frontmost browser's pid.
protocol BrowserNotificationObserving: AnyObject {
    associatedtype Node
    /// Called on the AX thread for every notification that maps to a trigger.
    var onTrigger: ((BrowserTrigger) -> Void)? { get set }
    /// Creates the observer on `pid` and registers the app-element notifications (focused/main window changed,
    /// focused element changed, title changed, load complete). false = the browser isn't ready yet (R2: right after
    /// launch it answers `kAXErrorCannotComplete`); nothing is left registered, and the caller retries.
    func attach(pid: Int32) -> Bool
    /// Gecko: `AXValueChanged` on this element only (the cached `urlbar-input`); nil = none. Replaces the previous one.
    func observeValueChanges(of node: Node?)
    /// Removes every registration and the run-loop source. Safe to call when not attached.
    func detach()
}

/// One timer on the AX thread's run loop, aimed at a monotonic deadline (the `Clock`'s nanos).
protocol DeadlineTimer: AnyObject {
    /// Called on the AX thread when the deadline passes.
    var onFire: (() -> Void)? { get set }
    /// Aims the timer at `nanos`, or removes it (nil): while detached there is no timer at all (B15).
    func schedule(atNanos nanos: UInt64?)
}
