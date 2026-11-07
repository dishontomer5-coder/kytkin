// P2-20 / P2-46 (001 §12 W7, §6.2): when to (re)start the keyboard tap. `KeyWatcher.start` blocks main for up to 1 s
// (about 2 s right after a stop that timed out, P2-50), so it is called only when it can change something:
//   - the desired mode changed (a grant, a setting, Pause) → start it (or stop, for `.off`);
//   - the desired mode is the same but the achieved mode is below it and a grant changed → retry once;
//   - never on a timer, never per event. A watchdog downgrade (B4) is not retried until a grant changes.
//   - P2-52 item 2: if the run's first start comes back below what was asked (a timeout on a busy system at launch),
//     one automatic retry on the next app activation (`activationRetry`). At most one per run: any later start
//     (a grant change, a user restart) uses it up, and it is never re-armed.
// P2-57 item 1: `runsBelow(desired:)` decides the "Some keyboard features are off" warning and the restart offer, so
// a failed restart or retry keeps the warning for as long as the tap stays below what the grants allow.
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
        startsThisRun += 1
        // P2-52 item 2: only the run's first start arms the retry; every later start (including the retry) disarms it.
        launchRetryArmed = startsThisRun == 1 && requested.map { Self.rank(mode) < Self.rank($0) } == true
    }

    /// P2-52 item 2: an app became active. The one automatic retry after the run's first start came back below the
    /// desired mode, when that mode is still what is wanted and still not running. Used up when returned.
    mutating func activationRetry(desired: TapMode) -> Action? {
        guard launchRetryArmed else { return nil }
        guard desired == requested, runsBelow(desired: desired) else { return nil }
        launchRetryArmed = false
        return .start(desired)
    }

    /// P2-57 item 1 (P2-52 item 2): the tap runs below what the grants and settings want (and something was asked
    /// for). The menu's "Some keyboard features are off" / watchdog warning and the Mode line follow this.
    func runsBelow(desired: TapMode) -> Bool {
        guard requested != nil, desired != .off else { return false }
        return Self.rank(achieved) < Self.rank(desired)
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

    /// P2-22: the menu's "Restart Keyboard Features" after a watchdog downgrade (B4), or (P2-57 item 1) any time the
    /// tap runs below the desired mode; a user click only: start the desired mode again when the tap runs below it. nil = nothing to do (off is wanted, or it already runs).
    func restartAction(desired: TapMode) -> Action? {
        guard runsBelow(desired: desired) else { return nil }
        return .start(desired)
    }

    /// P2-22: records the restart `restartAction` returned, like `decide` does for its own starts.
    mutating func restarting(_ desired: TapMode) {
        requested = desired
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
    /// P2-52 item 2: starts returned this run, and whether the one activation retry is still available.
    private var startsThisRun = 0
    private(set) var launchRetryArmed = false
}
