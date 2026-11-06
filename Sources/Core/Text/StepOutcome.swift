// P2-18: What one executed step did, plus whether the next step in the chain may still run.
// `StepVerdict` (001) is what `ReplacementCapabilities` learns from. `fieldUntouched` is the chain's safety
// brake: a failed AX write whose read-back shows the field changed in some unexpected way must not fall through
// to typing, or the text could end up doubled. Only a failure that left the original text in place may fall through.

import Foundation

struct StepOutcome: Sendable, Equatable {
    let verdict: StepVerdict
    /// True when the field is known to be as it was before the step (nothing written, or the write was a no-op).
    let fieldUntouched: Bool

    static let done = StepOutcome(verdict: .done, fieldUntouched: false)
    /// Couldn't run, nothing changed: the chain may try the next step.
    static let unavailable = StepOutcome(verdict: .unavailable, fieldUntouched: true)
}
