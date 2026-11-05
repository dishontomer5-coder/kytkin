// P2-13: What executing one ReplacementStep achieved (001 §2.2 `TextReplacing.execute`).

import Foundation

enum StepVerdict: Sendable, Equatable {
    /// The text changed and, where it can be checked, the read-back matched.
    case done
    /// The call reported success but the read-back didn't match (R5: NSTextField, WebKit selText).
    case failedVerify
    /// The step couldn't run here (attribute not settable, no AX element, timeout). Says nothing about the app.
    case unavailable
}
