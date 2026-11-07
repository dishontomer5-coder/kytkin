// P2-18: Runs a ReplacementPlan's steps in order until one is done (001 §2.2/§3c step 5, R5 fallback chains),
// and reports every verdict to `ReplacementCapabilities` (session memory only, never persisted: §12 T6).
//
//   - A step that fails but leaves the field untouched falls through to the next step.
//   - A step that fails with the field in an unknown state halts the chain (never type over a half-written field).
//   - P2-59 (001 §12.3 X4): `axReadRunBeforeCaret` supplies the text for the AX steps after it (through
//     `readRunBeforeCaret` and the caller's `locateRun`). Found a run → it is the text to replace. Read fine but
//     nothing there → `.exhausted`, nothing written. Unavailable → the AX steps after it are skipped (not run, not
//     recorded) and the key step, if any, runs on the caller's `old`.
//   - P2-59 key-step rule: `backspaceAndType` runs only if `old != nil` and `current` has exactly `old`'s scalars:
//     after a run read it deletes exactly what AX and the buffer agree is before the caret. Otherwise it is skipped
//     as untouched.
//   - Before the first step that writes to the field, `mayWrite` is asked once (ConvertController takes the
//     hold-back commit there, 001 §7 B3). false = abandon silently, nothing written.
//     P2-51 (001 §12.2 W8): "writes" covers AX writes as well as key posts. The AX step's own writes include the
//     stale path's `setRange` (it selects the word, and a held key replayed after that would type over it), so the
//     claim is taken before the step starts, which also puts the stale-range check under the claim: the deadline
//     flush can't replay held keys between that check and `AXSelectedText`. Read-only steps never ask.
//   - The whole run is bounded by `budgetNanos` (001 §7 B5: a convert gives up after 400 ms).
//   - P2-49 (enforced by the executor, so every plan shape gets it): nothing is written, and the chain ends
//     without a key, when (2) a type-over's selection has become a caret or changed length since `focusInfo`
//     (typing would insert the text twice); (3) the focused element is no longer the one `focusInfo` read
//     (`CFEqual` through `FocusedElementIdentity`), checked before every key step; (5) the app timed out once:
//     no further AX call (and no key step) in this replacement, and a write that timed out counts as unknown, so
//     the chain halts; (6) the subrole read failed or had the wrong type: the field counts as secure and the
//     planner refuses. AX writes still go to the element `focusInfo` read, so (3) only gates keys.

import Foundation

enum ReplacementChain {
    /// 001 §7 B5.
    static let defaultBudgetNanos: UInt64 = 400_000_000

    /// - Parameters:
    ///   - old: the text on screen now (selection or the buffer's rendering). nil when there is no buffer text; an
    ///     `axReadRunBeforeCaret` step then finds it.
    ///   - convert: maps the text on screen to its replacement. nil = can't convert (stop, nothing written).
    ///   - locateRun: P2-59: finds the run in the window an `axReadRunBeforeCaret` step read (the caller's scan,
    ///     which needs the layouts). nil = the read step can't run (unavailable).
    @TextActor
    static func run(_ plan: ReplacementPlan,
                    on replacer: some TextReplacing,
                    bundleID: String,
                    old: String?,
                    convert: (String) -> String?,
                    locateRun: ((BeforeCaretWindow) -> RunLocation?)? = nil,
                    capabilities: inout ReplacementCapabilities,
                    clock: any Clock = SystemClock(),
                    budgetNanos: UInt64 = defaultBudgetNanos,
                    mayWrite: () -> Bool = { true }) -> ReplacementOutcome {
        defer { replacer.endReplacement() }
        let steps: [ReplacementStep]
        switch plan {
        case .refuse(let r): return ReplacementOutcome(result: .refused(r), attempts: [])
        case .steps(let s): steps = s
        }
        let start = clock.nowNanos
        var attempts: [ReplacementOutcome.Attempt] = []
        var current = old
        var replacement: String?
        var writeClaimed = false
        /// P2-59: the run read was unavailable, so the AX steps that depend on it don't run.
        var skipAXSteps = false

        for step in steps {
            let isKeyStep = if case .backspaceAndType = step { true } else { false }
            if skipAXSteps && !isKeyStep { continue }
            // P2-59 (X4): delete only what is known to be before the caret. QA (P2-59b): compared scalar by scalar,
            // not with `==` (canonical equivalence): an AX run in another normalization (`e` + U+0301 for `é`) is
            // the same grapheme count but some apps delete it a scalar at a time, so Backspace × N would be wrong.
            if isKeyStep, !Self.sameScalars(current, old) { continue }
            if clock.nowNanos &- start > budgetNanos {
                return ReplacementOutcome(result: .timedOut, attempts: attempts)
            }
            var oldText = "", newText = ""
            if !isRead(step) {
                guard let text = current, !text.isEmpty else {
                    return ReplacementOutcome(result: .exhausted, attempts: attempts)
                }
                if replacement == nil { replacement = convert(text) }
                guard let r = replacement, !r.isEmpty else {
                    return ReplacementOutcome(result: .notConvertible, attempts: attempts)
                }
                oldText = text
                newText = r
            }
            if !isRead(step) && !writeClaimed {
                guard mayWrite() else { return ReplacementOutcome(result: .abandoned, attempts: attempts) }
                writeClaimed = true
            }

            let outcome: StepOutcome
            if case .axReadRunBeforeCaret(let maxChars) = step, let locateRun {
                outcome = replacer.readRunBeforeCaret(maxChars: maxChars, locate: locateRun)
            } else {
                outcome = replacer.perform(step, old: oldText, new: newText)
            }
            capabilities.record(outcome.verdict, of: step, for: bundleID)
            attempts.append(.init(step: step, verdict: outcome.verdict))

            if outcome.verdict == .done {
                guard isRead(step) else { return ReplacementOutcome(result: .replaced(by: step), attempts: attempts) }
                // The read found the run; the steps after it replace that run. Read fine, nothing there: done.
                guard let run = replacer.wordBeforeCaret, !run.isEmpty else {
                    return ReplacementOutcome(result: .exhausted, attempts: attempts)
                }
                current = run
                replacement = nil
                continue
            }
            if !outcome.fieldUntouched { return ReplacementOutcome(result: .halted(after: step), attempts: attempts) }
            if isRead(step) {
                skipAXSteps = true
                current = old
                replacement = nil
            }
        }
        return ReplacementOutcome(result: .exhausted, attempts: attempts)
    }

    /// P2-59b QA: exactly the same text (same scalars), both non-nil. `String ==` is canonical equivalence.
    private static func sameScalars(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// The only step that writes nothing (not even a selection range). P2-51: every other step, including any
    /// added later, counts as a write and takes the claim first.
    private static func isRead(_ step: ReplacementStep) -> Bool {
        if case .axReadRunBeforeCaret = step { return true }
        return false
    }
}
