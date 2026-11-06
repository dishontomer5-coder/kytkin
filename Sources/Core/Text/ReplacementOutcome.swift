// P2-18: The result of running one ReplacementPlan (what ConvertController, P2-21, acts on: beep or not,
// switch the layout or not). Holds steps and verdicts only, never text.

import Foundation

struct ReplacementOutcome: Sendable, Equatable {
    enum Result: Sendable, Equatable {
        /// The text was replaced by this step.
        case replaced(by: ReplacementStep)
        /// The planner refused; nothing was tried.
        case refused(ReplacementPlan.Refusal)
        /// The text to replace couldn't be converted (e.g. its layout isn't in the pair). Nothing written.
        case notConvertible
        /// Every step failed and the field is as it was.
        case exhausted
        /// A step failed in a way that may have changed the field, so the chain stopped instead of guessing.
        case halted(after: ReplacementStep)
        /// The caller withdrew permission to post keys (the hold-back deadline won, 001 §7 B3). Nothing posted.
        case abandoned
        /// The 400 ms convert budget (001 §7 B5) ran out before a step could start.
        case timedOut
    }

    struct Attempt: Sendable, Equatable {
        let step: ReplacementStep
        let verdict: StepVerdict
    }

    let result: Result
    let attempts: [Attempt]

    var succeeded: Bool {
        if case .replaced = result { return true }
        return false
    }

    /// R5: a failure is a no-op with a beep, never a guess. An abandoned convert is silent: the user's keys
    /// were already flushed through, and a beep would only confuse.
    var shouldBeep: Bool { !succeeded && result != .abandoned }
}
