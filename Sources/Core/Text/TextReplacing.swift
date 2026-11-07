// P2-18: The text replacer's contract (001 §2.2 `TextReplacing`), used by ConvertController (P2-21) and
// `ReplacementChain`. One replacement is: `focusInfo` → plan → `perform` each step → `endReplacement`.
// The live implementation is `System/Text/TextReplacer`; tests use `ReplacementExecutor` with fake seams.
//
// Deviations from the 001 sketch (reported in P2-18): isolated to @TextActor (it holds AX elements, which
// aren't Sendable); `perform` returns a `StepOutcome` so the chain knows whether a failure left the field
// untouched; `wordBeforeCaret` hands the stale-buffer word back to the caller to convert.

import Foundation

@TextActor protocol TextReplacing: AnyObject {
    /// Reads the focused element's facts through AX (each call bounded by `timeout`). nil = AX couldn't tell
    /// (no permission, no focused element, the app didn't answer), so the planner refuses (001 §12 T4).
    /// Starts a new replacement: anything held from the previous one is dropped first.
    func focusInfo(timeout: Double) -> FocusInfo?

    /// Runs one step. `old` is the text on screen now (the selection, the current rendering of the word, or the
    /// run found by `axReadRunBeforeCaret`); `new` is what replaces it.
    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome

    /// P2-59 (001 §12.3 X4): the `axReadRunBeforeCaret` step. Reads ≤ `maxChars` UTF-16 units before the caret
    /// (one `AXStringForRange`), and asks `locate` where the run is. A run → `.done`, `wordBeforeCaret` = the run and
    /// the next AX write targets its range. `locate` returns nil → `.done` with `wordBeforeCaret == nil` ("read fine,
    /// nothing there"). Any AX failure, or no caret → `.unavailable` (untouched). Writes nothing.
    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome

    /// The run found by the last successful `axReadRunBeforeCaret` step, in memory for this replacement only.
    var wordBeforeCaret: String? { get }

    /// P2-59c (001 §12.3 X6): the element the last `focusInfo` read as safe (not secure, not composing), until
    /// `endReplacement`. Identity only, for the undo record's same-element check; nil = unknown.
    var focusedElement: (any FocusedElementIdentity)? { get }

    /// Drops the element, ranges and any text held for this replacement (privacy: nothing outlives it).
    func endReplacement()
}

extension TextReplacing {
    /// P2-59c: a replacer that can't name its element never gets an undo record (the safe default).
    var focusedElement: (any FocusedElementIdentity)? { nil }

    /// 001 §2.2's signature: just the verdict.
    func execute(_ step: ReplacementStep, old: String, new: String) -> StepVerdict {
        perform(step, old: old, new: new).verdict
    }
}
