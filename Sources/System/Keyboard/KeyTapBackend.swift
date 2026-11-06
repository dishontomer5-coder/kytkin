// P2-17: The thin seam between KeyTapEngine (all the plumbing, unit-tested) and the real CGEventTap, run loop
// timers and system queries (CGEventTapBackend, never used in tests). Every method is called on the tap thread.
// Tests use a fake: they never install a tap or post an event (live-machine rule).

import CoreGraphics
import Foundation

protocol KeyTapBackend: AnyObject {
    /// Called for every tap event. Return true to let it through, false to swallow it (active tap only).
    typealias EventHandler = (CGEventType, CGEvent) -> Bool

    /// Create and enable a session tap in `mode` (`.active` = `.defaultTap`, `.listenOnly` = `.listenOnly`).
    /// False = `tapCreate` failed (no permission). Never called with `.off`.
    func install(mode: TapMode, handler: @escaping EventHandler) -> Bool
    /// Remove the tap, if any. Safe to call when nothing is installed.
    func uninstall()
    /// `CGEvent.tapIsEnabled`. False when no tap is installed.
    var isEnabled: Bool { get }
    /// `CGEvent.tapEnable(tap:enable:true)`.
    func reEnable()

    /// Silent permission check for a mode (never prompts): active → `AXIsProcessTrusted()`,
    /// listen-only → `CGPreflightListenEventAccess()`. Installing without it could show a system prompt.
    func isGranted(_ mode: TapMode) -> Bool

    /// Re-post a held event (already marked `replay`) into the session event stream.
    func post(_ event: CGEvent)

    /// `IsSecureEventInputEnabled()`.
    var isSecureInputEnabled: Bool { get }
    /// `CGEventSource.flagsState(.combinedSessionState)`, to re-seed a Shift held across a reset.
    var currentDeviceFlags: UInt64 { get }

    /// Called once by the engine: the deadline timer's and the 1 s poll timer's tap-thread handlers.
    /// (Set once so arming a deadline in the callback never allocates a closure.)
    func attachTimers(deadline: @escaping () -> Void, poll: @escaping () -> Void)
    /// One-shot deadline at `uptimeNanos` (same base as `Clock`). Re-arming replaces the old time.
    func armDeadline(atUptimeNanos: UInt64)
    func cancelDeadline()
    /// Run a block on the tap thread after the current callback returns (e.g. replacing the tap from inside it).
    func runSoon(_ block: @escaping () -> Void)
}
