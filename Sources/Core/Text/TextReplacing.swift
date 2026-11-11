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

    /// P3-35 (001 §12.3 X11): the `axReadField` step. Reads the whole field (≤ `maxChars` UTF-16 units, else a window
    /// around the caret; smaller windows if a read fails or has the wrong length) and asks `locate` what to replace.
    /// An edit → `.done`, `wordBeforeCaret` = the text in its range, the next AX write targets that range and then
    /// puts the caret at `caretAfter`. `locate` returns nil → `.done` with `wordBeforeCaret == nil`. Any AX failure,
    /// or no caret → `.unavailable` (untouched). Writes nothing.
    func readField(maxChars: Int, locate: (FieldWindow) -> FieldEdit?) -> StepOutcome

    /// The run found by the last successful `axReadRunBeforeCaret` / `axReadField` step, in memory for this
    /// replacement only.
    var wordBeforeCaret: String? { get }

    /// P3-35: the range found by the last read step ends at the caret, so a key fallback (Backspace × N from the
    /// caret) would delete exactly it. False for a whole-box range that reaches past the caret.
    var readRangeEndsAtCaret: Bool { get }

    /// P2-59c (001 §12.3 X6): the element the last `focusInfo` read as safe (not secure, not composing), until
    /// `endReplacement`. Identity only, for same-element checks (P3-37 clipboard, terminal anchor); nil = unknown.
    var focusedElement: (any FocusedElementIdentity)? { get }

    /// Drops the element, ranges and any text held for this replacement (privacy: nothing outlives it).
    func endReplacement()

    /// P3-37: the focused element now (identity only; reads no text and starts no replacement), for the clipboard
    /// convert's focus re-check before each shortcut and the terminal buffer's same-window check. nil = unknown.
    func currentFocusedElement(timeout: Double) -> (any FocusedElementIdentity)?

    /// P3-41: a terminal's key step when AX can't vouch for the focus (Ghostty-based terminals such as cmux may name no
    /// focused element, or a different one on every read, or answer the secure/marked-text reads with errors): Backspace
    /// × `count`, then `new`, with the same event rules as `.backspaceAndType` (no line break, no control character, the
    /// `ours` marker, no modifiers) but no AX check. The caller decides when that is allowed.
    func postTerminalKeys(count: Int, new: String) -> StepOutcome

    /// P3-41 QA: the pid of the app AX says has focus now, nil = unknown. Identity only. Lets the terminal fallback
    /// refuse when another app is in front even where AX names no focused element.
    func focusedApplicationPID(timeout: Double) -> Int32?
}

extension TextReplacing {
    /// P2-59c: a replacer that can't name its element: no clipboard convert, no terminal anchor (the safe default).
    var focusedElement: (any FocusedElementIdentity)? { nil }

    /// P3-41: a replacer without a key poster posts nothing (the safe default).
    func postTerminalKeys(count: Int, new: String) -> StepOutcome { .unavailable }

    /// P3-41 QA: unknown by default.
    func focusedApplicationPID(timeout: Double) -> Int32? { nil }

    /// P3-37: a replacer that can't name the focus never passes a focus re-check (the safe default).
    func currentFocusedElement(timeout: Double) -> (any FocusedElementIdentity)? { nil }

    /// P3-35: a replacer that can't tell keeps the P2-59 rule (the run read always ended at the caret).
    var readRangeEndsAtCaret: Bool { true }

    /// 001 §2.2's signature: just the verdict.
    func execute(_ step: ReplacementStep, old: String, new: String) -> StepVerdict {
        perform(step, old: old, new: new).verdict
    }
}
