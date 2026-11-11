// P2-12: What the processor tells the rest of the app (001 §2.2). The adapter sends it off the tap thread.

import Foundation

enum KeySignal: Sendable, Equatable {
    /// Convert request (second Shift release).
    case doubleShift(WordSnapshot, gen: UInt64)
    /// P4 auto-fix trigger: a Space / Return / Tab was held back after this word.
    case wordEnded(WordSnapshot, gen: UInt64)
    /// A word was completed (for RuleLearner).
    case wordBoundary
    /// The buffer was cleared (mouse, navigation, shortcut, reset) while it held something.
    case bufferInvalidated
    /// P4: Backspace right after a fix. Not emitted yet: undo records arrive with auto-fix in P4.
    case undoCandidate(gen: UInt64)
    /// P3-35 QA (owner): the first key, click or tap reset after a finished convert. The convert's undo record (it holds
    /// the replaced text) is dropped then, not after a timer. Ids only, no text; sent at most once per convert.
    case undoTouched
}
