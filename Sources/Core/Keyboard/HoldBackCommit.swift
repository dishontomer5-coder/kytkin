// P2-12: The pure part of the hold-back commit (001 §7 B3). A replacement worker and the tap's deadline race
// for one generation: whoever claims first decides. The worker may post only if it claims `posting` while the
// state is still `pending`; the deadline may flush only if the worker hasn't. The System adapter keeps this
// one-word state behind a tiny lock (Core can't import `os`); everything here is lock-free value logic.

import Foundation

struct HoldBackCommit: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case idle
        case pending(gen: UInt64)
        case posting(gen: UInt64)
        case flushed(gen: UInt64)
    }

    private(set) var state: State = .idle

    init() {}

    /// Tap thread, when a replacement starts.
    mutating func arm(gen: UInt64) {
        state = .pending(gen: gen)
    }

    /// Worker, right before posting. False = the deadline won (or another generation is active): abandon.
    mutating func claimPosting(gen: UInt64) -> Bool {
        guard state == .pending(gen: gen) else { return false }
        state = .posting(gen: gen)
        return true
    }

    /// Tap thread, when the deadline passes. False = the worker is posting this generation: wait for it
    /// (up to the hard cap). True for anything else, because then nothing is being posted.
    mutating func claimFlush(gen: UInt64) -> Bool {
        if state == .posting(gen: gen) { return false }
        if state == .pending(gen: gen) { state = .flushed(gen: gen) }
        return true
    }

    /// Either side, when this generation is over.
    mutating func finish(gen: UInt64) {
        switch state {
        case .pending(let g), .posting(let g), .flushed(let g):
            if g == gen { state = .idle }
        case .idle:
            break
        }
    }
}
