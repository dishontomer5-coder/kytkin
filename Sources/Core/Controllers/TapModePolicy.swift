// P2-20 / P2-46 (001 §12 W7, §6.2): when to (re)start the keyboard tap. `KeyWatcher.start` blocks main for up to 1 s
// (about 2 s right after a stop that timed out, P2-50), so it is called only when it can change something:
//   - the desired mode changed (a grant, a setting, Pause) → start it (or stop, for `.off`);
//   - the desired mode is the same but the achieved mode is below it and a grant changed → retry once;
//   - never on a timer, never per event. A watchdog downgrade (B4) is not retried until a grant changes.
// A stop that timed out is treated as `.off` (the tap thread ends there by itself, P2-50).
// Pure; AppController applies the action and reports the result back.

import Foundation

struct TapModePolicy: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case start(TapMode)
        case stop
    }

    /// The mode last asked for (nil = never decided yet).
    private(set) var requested: TapMode?
    /// The mode actually running, from `start`'s answer and from `KeyWatcherStatus.health.mode`.
    private(set) var achieved: TapMode = .off

    init() {}

    /// What to do now. `grantsChanged`: the call comes from a real permission change.
    mutating func decide(desired: TapMode, grantsChanged: Bool) -> Action? {
        if desired != requested {
            requested = desired
            if desired == .off {
                // Nothing to stop the very first time, or when the tap already is off.
                return achieved == .off && !hadTap ? nil : .stop
            }
            return .start(desired)
        }
        if grantsChanged, desired != .off, Self.rank(achieved) < Self.rank(desired) {
            return .start(desired)
        }
        return nil
    }

    /// After `start` returned (`.off` on a timeout or failed permission check).
    mutating func started(achieved mode: TapMode) {
        achieved = mode
        hadTap = true
    }

    /// After `stop()` returned, timed out or not.
    mutating func stopped() {
        achieved = .off
        hadTap = false
    }

    /// `KeyWatcherStatus.health.mode` changed (e.g. the watchdog lowered it).
    mutating func statusReported(mode: TapMode) {
        achieved = mode
    }

    /// The tap stays below what the grants allow while Input Monitoring was granted during this run: the UI offers
    /// "Quit & Reopen" (P2-46, 001 §6.1 step 4).
    func showsQuitAndReopen(needsRelaunch: Bool) -> Bool {
        guard needsRelaunch, let requested else { return false }
        return Self.rank(achieved) < Self.rank(requested)
    }

    static func rank(_ m: TapMode) -> Int {
        switch m {
        case .off: 0
        case .listenOnly: 1
        case .active: 2
        }
    }

    /// A tap thread was started and not stopped since (it may run at `.off` after a failed start).
    private var hadTap = false
}
