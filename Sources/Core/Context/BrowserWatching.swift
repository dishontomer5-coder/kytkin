// P3-10: The tier-1 seam ContextMonitor talks to (001 §14.2, §14.5). System/Browser/BrowserWatcher implements it;
// ContextMonitor is wired to it in P3-14, whose tests use a fake. Every call returns at once: the work happens on
// the AX thread, and results come back to main asynchronously (B16: main never waits on the AX thread).
// P3-14: each result also says whether the read saw a window, for `BrowserSupportTracker.record` (a `.unknown` with
// no window open says nothing about whether Kytkin can read the browser).

@MainActor protocol BrowserWatching: AnyObject {
    /// One observation of the frontmost browser, posted only when its facts changed (and after every attach or
    /// wake). `attachID` is the attach it was read for; a result for an older attach is never delivered.
    /// `sawWindow`: the read found a window to read (for the support tracker only).
    var onObservation: (@MainActor (_ pid: Int32, _ attachID: UInt64, BrowserObservation, _ sawWindow: Bool) -> Void)? {
        get set
    }
    /// Watches `pid` (the frontmost browser) and reads it at once. The same pid with the same request → no
    /// re-attach, just a read; returns the current attachID.
    @discardableResult func attach(pid: Int32, bundleID: String, request: BrowserWatchRequest) -> UInt64
    /// Stops watching: no observer, no timer, no AX calls until the next attach (B15).
    func detach()
    /// After sleep or a session switch: re-read now.
    func wake()
}
