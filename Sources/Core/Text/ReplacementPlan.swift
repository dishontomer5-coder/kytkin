// P2-13: The planner's answer: an ordered chain of steps, or the reason nothing may be done.
// A refusal means "no-op with feedback" (a beep), never a guess (R5).

import Foundation

enum ReplacementPlan: Sendable, Equatable {
    enum Refusal: Sendable, Equatable {
        /// The user disabled text replacement for this app.
        case disabledForApp
        /// AX gave no focus facts, so a secure field or IME composition can't be ruled out.
        case focusUnknown
        /// Password field. Never write into it (design.md).
        case secureField
        /// IME composition in progress. Never write while composing (design.md).
        case composing
        /// A selection convert, but the selected text couldn't be read.
        case selectionUnreadable
        /// No valid buffer and no AX path to find the last word.
        case bufferStale
        /// Nothing in the chain can work in this app/field (e.g. keys-only app with AX-only needs).
        case noMethod
    }

    case steps([ReplacementStep])
    case refuse(Refusal)

    /// The steps to try, or [] for a refusal (001's `[ReplacementStep]` shape).
    var steps: [ReplacementStep] {
        if case .steps(let s) = self { return s }
        return []
    }
}
