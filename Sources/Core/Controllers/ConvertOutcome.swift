// P2-21: What one double-Shift did (001 §2.2 `ConvertController.handle → ConvertOutcome`). Steps, ids and reasons
// only, never text (privacy, B12): the outcome may be kept for diagnostics and tests.

import Foundation

enum ConvertOutcome: Sendable, Equatable {
    enum ToggleReason: Sendable, Equatable {
        /// The request was toggle-only (no Accessibility, listen-only tap, Secure Input, convert off for the app).
        case toggleMode
        /// No selection and no last word to convert (empty buffer and nothing before the caret, or nothing that
        /// either layout types, like digits): double-Shift just switches the language.
        case nothingToConvert
        /// P2-54(a) (owner, 2026-11-07): AX couldn't read the focused field (focus unknown) and the buffer is empty,
        /// so there is nothing Kytkin could convert: double-Shift just switches the language, without a beep.
        case fieldUnreadable
        /// P2-54(a): the pair's layout maps aren't available (an input method with no layout data) and the buffer
        /// is empty: the same silent switch. With a buffer it stays `.noop(.layoutsUnavailable)` and beeps.
        case layoutsUnavailable
        /// P3-44: the clipboard copy was rich (bold, mentions, emoji, links…), so nothing was pasted, and no typed run
        /// could be converted by keys at the caret: double-Shift just switches the language.
        case richContent
    }

    enum NoopReason: Sendable, Equatable {
        /// An older generation than one already handled (out-of-order delivery). Finished, nothing done.
        case staleGeneration
        /// The task was cancelled before it started work.
        case cancelled
        /// The pair's layout maps aren't available (an input method with no layout data), with words in the buffer.
        /// Beeps. (Empty buffer: `toggledOnly(.layoutsUnavailable)`, P2-54(a).)
        case layoutsUnavailable
        /// The text's (or the current) layout isn't in the active pair (001 §3 (c) step 4). Beeps.
        case notInPair
        /// The toggle's input-source select failed. Beeps.
        case switchFailed
        /// P2-59 (001 §12.3 X2): the run before the caret is a single token longer than the window (a URL, a hash;
        /// P3-33 QA: 4,096 units, was 256). Nothing written. Beeps.
        case runTooLong
        /// The replacement chain didn't replace anything (refused, notConvertible, exhausted, halted, abandoned,
        /// timedOut). Beeps exactly when `ReplacementOutcome.shouldBeep` does (abandoned is silent).
        case replacement(ReplacementOutcome.Result)
    }

    /// The text was replaced by `step`; `switched` = the input source is now `target`.
    case converted(to: InputSourceID, by: ReplacementStep, switched: Bool)
    /// Only the input source changed (to `target`).
    case toggledOnly(to: InputSourceID, because: ToggleReason)
    case noop(NoopReason)
}
