// P4-5: turns on the accessibility tree of a chat app (Slack, Discord, Teams: Electron) once per process, through the
// `ManualAccessibilitySetting` seam. Asked when a chat app launches or comes to the front (AppController →
// ConvertDispatcher → ConvertController's launch schedule, on @TextActor, never on main) and, as a safety net, by the
// double-Shift itself (ConvertController).
//
// Rules:
//   - Chat apps only (`ReplacementCapabilities.isChatApp`). Browsers never: R3b rule 1 (no attribute is ever set on a
//     browser) stays.
//   - Once per pid: an answered write (`set`, or `refused`, see `ManualAccessibilityAnswer`) is remembered for that pid;
//     a relaunched app has a new pid and is asked again. `noAnswer` / `notTrusted` are not remembered (asked next time).
//   - `force`: write again even for a remembered pid (the window looks bare: the tree may have been dropped).
//     P4-5c (owner live test 2026-11-18: Slack needs 1–2 s to build its tree after the write, and a re-write every
//     ~0.9 s kept it from ever finishing): never within `minRewriteIntervalNanos` of the last write to that pid
//     (`.throttled`).
//   - P4-5c: per pid, counts for the DEBUG trace: schedule tries, writes, the last answer, and whether the focused
//     window was last seen with a real tree (`built`).
//   - Remembers at most `maxRemembered` pids (oldest dropped first), so a long session with many relaunches stays small.
//
// Holds only pids, times and counts: nothing from the app is read, kept or logged.

import Foundation

@TextActor final class ChatAccessibilityEnabler {
    /// What `enable` did, for the caller and the DEBUG trace (enum names and numbers only).
    enum Result: Equatable, Sendable {
        /// Not a chat app, or no pid: nothing sent.
        case notChatApp
        /// Done before for this pid (`ageMs` since the last write): nothing sent.
        case alreadySet(ageMs: UInt64)
        /// P4-5c: a forced re-write within `minRewriteIntervalNanos` of the last write: nothing sent.
        case throttled(ageMs: UInt64)
        /// Written now (the tree may need a moment to appear).
        case wrote(ManualAccessibilityAnswer)

        var traceName: String {
            switch self {
            case .notChatApp: "notChatApp"
            case .alreadySet(let age): "alreadySet(age=\(age)ms)"
            case .throttled(let age): "throttled(age=\(age)ms)"
            case .wrote(let a): "wrote:\(a.rawValue)"
            }
        }

        /// The flag is (now) set for this pid.
        var isSet: Bool {
            switch self {
            case .alreadySet, .throttled, .wrote(.set), .wrote(.refused): true
            default: false
            }
        }
    }

    /// P4-5c: what is known about one chat process (numbers and enums only).
    struct PidState: Equatable, Sendable {
        var answered = false
        var lastWriteNanos: UInt64?
        var lastAnswer: ManualAccessibilityAnswer?
        var writes = 0
        var tries = 0
        /// The focused window was last seen with a real tree (true), bare (false), or not looked at / unknown (nil).
        var built: Bool?
    }

    static let maxRemembered = 64
    /// The messaging timeout when a chat app launches or comes to the front (the usual B5 timeout).
    static let frontmostTimeout: Double = 0.25
    /// The messaging timeout at double-Shift time (inside the 400 ms budget).
    static let requestTimeout: Double = 0.1
    /// P4-5c: no re-write to a pid within this long of the last write (its tree takes 1–2 s to build).
    static let minRewriteIntervalNanos: UInt64 = 3_000_000_000

    private let setter: any ManualAccessibilitySetting
    private let clock: any Clock
    /// P4-5c: whether the process still runs (live: a signal-0 check; tests: a fake). Never sends anything to the app.
    let isAlive: @Sendable (Int32) -> Bool
    private var states: [Int32: PidState] = [:]
    private var order: [Int32] = []

    nonisolated init(setter: any ManualAccessibilitySetting, clock: any Clock = SystemClock(),
                     isAlive: @escaping @Sendable (Int32) -> Bool = { _ in true }) {
        self.setter = setter
        self.clock = clock
        self.isAlive = isAlive
    }

    /// True when a write for `pid` was answered.
    func isSet(pid: Int32) -> Bool { states[pid]?.answered == true }

    /// P4-5c: answered and the focused window was seen with a real tree: nothing more to do for this pid.
    func isReady(pid: Int32) -> Bool { states[pid].map { $0.answered && $0.built == true } ?? false }

    func state(pid: Int32) -> PidState? { states[pid] }

    /// P4-5c: one launch-schedule try (counted for the trace).
    func noteTry(pid: Int32) { update(pid) { $0.tries += 1 } }

    /// P4-5c: what the last look at the focused window found.
    func noteBuilt(pid: Int32, _ built: Bool?) { update(pid) { $0.built = built } }

    /// P4-5c: the process is gone.
    func forget(pid: Int32) {
        states[pid] = nil
        order.removeAll { $0 == pid }
    }

    /// P4-5c: ms since the last write to `pid` (nil = never written).
    func lastWriteAgeMs(pid: Int32) -> UInt64? {
        states[pid]?.lastWriteNanos.map { (clock.nowNanos &- $0) / 1_000_000 }
    }

    /// P4-5c: the pid's counts for the DEBUG trace, e.g. `tries=3 writes=2 last=noAnswer built=no`.
    func summary(pid: Int32) -> String {
        guard let s = states[pid] else { return "none" }
        let built = s.built.map { $0 ? "yes" : "no" } ?? "unknown"
        return "tries=\(s.tries) writes=\(s.writes) last=\(s.lastAnswer?.rawValue ?? "-") built=\(built)"
    }

    @discardableResult
    func enable(bundleID: String, pid: Int32?, timeout: Double, force: Bool = false) -> Result {
        guard let pid, pid > 0, ReplacementCapabilities.isChatApp(bundleID) else { return .notChatApp }
        let now = clock.nowNanos
        if let s = states[pid], s.answered, let last = s.lastWriteNanos {
            let age = (now &- last) / 1_000_000
            if !force { return .alreadySet(ageMs: age) }
            if now &- last < Self.minRewriteIntervalNanos { return .throttled(ageMs: age) }
        }
        let answer = setter.setManualAccessibility(pid: pid, timeout: timeout)
        update(pid) { s in
            s.writes += 1
            s.lastWriteNanos = now
            s.lastAnswer = answer
            if answer == .set || answer == .refused {
                s.answered = true
                s.built = nil   // a write may restart the build
            }
        }
        return .wrote(answer)
    }

    private func update(_ pid: Int32, _ change: (inout PidState) -> Void) {
        var s = states[pid] ?? PidState()
        change(&s)
        if states[pid] == nil {
            order.append(pid)
            if order.count > Self.maxRemembered {
                for old in order.prefix(order.count - Self.maxRemembered) { states[old] = nil }
                order.removeFirst(order.count - Self.maxRemembered)
            }
        }
        states[pid] = s
    }
}
