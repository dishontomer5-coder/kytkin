// P2-20: What the controllers need from the keyboard watcher (001 §2.1 hops, §2.2 KeyWatcher). `KeyWatcher`
// (System/Keyboard) conforms in `KeyWatcher+KeyWatching.swift`; controller tests use a fake, so no test ever
// installs a tap.
//
// Threading: `start`, `stop`, `perform` and `checkSecureInputNow` are main only (P2-50 enforces it with
// `dispatchPrecondition`). `start` and `stop` wait for the tap thread (≤ 1 s each), so call `start` only when the
// desired mode changed (§12 W7, `TapModePolicy`). `claimPosting` / `finishReplacement` may come from any thread.

import Foundation

protocol KeyWatching: AnyObject, Sendable {
    /// Installs the tap in `mode`; returns the mode achieved (`.off` on a failed permission check or a timeout).
    @discardableResult func start(mode: TapMode) -> TapMode
    /// Removes the tap and ends the tap thread. A stop that times out is treated as `.off` by the caller.
    func stop()
    func perform(_ operation: KeyWatcherOperation)
    func checkSecureInputNow()
    /// The replacement worker, right before its first write (B3). False = abandon.
    func claimPosting(gen: UInt64) -> Bool
    /// Every generation a `.doubleShift` / `.wordEnded` signal armed must end here, whatever happened, so held keys
    /// replay at once instead of waiting for the deadline (or the 1 s hard cap).
    func finishReplacement(gen: UInt64, newRendering: InputSourceID?, bufferAfter: [Stroke]?)
}
