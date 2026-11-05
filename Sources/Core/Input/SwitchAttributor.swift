// P2-10: Tells Kytkin's own input-source switches from everyone else's (R1 §3, 001 §2.2 and §3 flows (a)/(b)).
//
// TIS change notifications carry no sender and often arrive twice, 10–20 ms after the switch (R1).
// So before every `TISSelectInputSource` the switcher (P2-14) calls `willSelect`, which stores an
// "expected switch" token: the target plus a deadline 500 ms later. Each notification then goes through
// `didObserve(current:)`:
//   - the same source as last time        → nil (duplicate delivery, or nothing changed)
//   - the token's target, before deadline → `.ours` (the token is consumed: it matches once)
//   - anything else                       → `.external` (the token, if any, is dropped)
//
// Edge rules (fixed here, tested in SwitchAttributorTests):
//   - The deadline is exclusive: a change at exactly `willSelect + 500 ms` is external (R1 sketch: `now < deadline`).
//   - `willSelect` for the source that's already current stores no token: TIS sends no notification
//     for a no-op select, and a stale token could swallow a real user switch back to it.
//   - A newer `willSelect` replaces the older token (only the latest request is expected).
//   - If `TISSelectInputSource` fails, the switcher calls `selectFailed()`: no notification will come, and a
//     leftover token would swallow a real user switch to that source within 500 ms (P2-10 QA).
//
// Time comes from the injected `Clock` (design.md) or, in the `atNanos:` overloads (the 001 contract),
// from the caller. Both are monotonic nanoseconds.

import Foundation

struct SwitchAttributor {
    /// R1 / 001 §7 B8: how long a token stays valid.
    static let defaultTokenWindowNanos: UInt64 = 500_000_000

    private struct Token {
        let target: InputSourceID
        let deadline: UInt64
    }

    private let clock: any Clock
    let tokenWindowNanos: UInt64
    /// The source the last notification reported (or the one given at init). Used to drop duplicates.
    private(set) var lastKnown: InputSourceID?
    private var token: Token?

    /// `current` is the source selected at startup, so the first notification can be deduped against it.
    init(clock: any Clock, current: InputSourceID? = nil, tokenWindowNanos: UInt64 = defaultTokenWindowNanos) {
        self.clock = clock
        self.lastKnown = current
        self.tokenWindowNanos = tokenWindowNanos
    }

    /// True while an unexpired token is waiting for its notification (for tests and the DEBUG menu).
    func hasPendingToken(atNanos now: UInt64) -> Bool {
        guard let token else { return false }
        return now < token.deadline
    }

    // MARK: - Clock-driven API

    mutating func willSelect(_ id: InputSourceID) {
        willSelect(id, atNanos: clock.nowNanos)
    }

    mutating func didObserve(current: InputSourceID) -> InputSourceChange? {
        didObserve(current: current, atNanos: clock.nowNanos)
    }

    // MARK: - Timestamped API (001 §2.2 signatures)

    mutating func willSelect(_ id: InputSourceID, atNanos now: UInt64) {
        // P2-10: no-op select → no notification will come, so don't leave a token behind.
        guard id != lastKnown else {
            token = nil
            return
        }
        let (deadline, overflow) = now.addingReportingOverflow(tokenWindowNanos)
        token = Token(target: id, deadline: overflow ? .max : deadline)
    }

    /// P2-10 QA: the select didn't happen (TIS returned an error), so drop the token it set.
    mutating func selectFailed() {
        token = nil
    }

    /// nil = duplicate (the source didn't change since the last notification).
    mutating func didObserve(current: InputSourceID, atNanos now: UInt64) -> InputSourceChange? {
        guard current != lastKnown else { return nil }
        lastKnown = current
        let pending = token
        token = nil   // P2-10: a token matches at most once; any real change clears it
        if let pending, pending.target == current, now < pending.deadline {
            return .ours(current)
        }
        return .external(current, atNanos: now)
    }
}
