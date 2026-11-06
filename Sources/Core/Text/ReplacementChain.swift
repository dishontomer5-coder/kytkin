// P2-18: Runs a ReplacementPlan's steps in order until one is done (001 §2.2/§3c step 5, R5 fallback chains),
// and reports every verdict to `ReplacementCapabilities` (session memory only, never persisted: §12 T6).
//
//   - A step that fails but leaves the field untouched falls through to the next step.
//   - A step that fails with the field in an unknown state halts the chain (never type over a half-written field).
//   - `axReadBeforeCaret` supplies the text for the steps after it; if it fails, nothing after it can run.
//   - Before the first step that writes to the field, `mayWrite` is asked once (ConvertController takes the
//     hold-back commit there, 001 §7 B3). false = abandon silently, nothing written.
//     P2-51 (001 §12.2 W8): "writes" covers AX writes as well as key posts. The AX step's own writes include the
//     stale path's `setRange` (it selects the word, and a held key replayed after that would type over it), so the
//     claim is taken before the step starts, which also puts the stale-range check under the claim: the deadline
//     flush can't replay held keys between that check and `AXSelectedText`. Read-only steps never ask.
//   - The whole run is bounded by `budgetNanos` (001 §7 B5: a convert gives up after 400 ms).

import Foundation

enum ReplacementChain {
    /// 001 §7 B5.
    static let defaultBudgetNanos: UInt64 = 400_000_000

    /// - Parameters:
    ///   - old: the text on screen now (selection or current rendering). nil for the stale-buffer path, where
    ///     `axReadBeforeCaret` finds it.
    ///   - convert: maps the text on screen to its replacement. nil = can't convert (stop, nothing written).
    @TextActor
    static func run(_ plan: ReplacementPlan,
                    on replacer: some TextReplacing,
                    bundleID: String,
                    old: String?,
                    convert: (String) -> String?,
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

        for step in steps {
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

            let outcome = replacer.perform(step, old: oldText, new: newText)
            capabilities.record(outcome.verdict, of: step, for: bundleID)
            attempts.append(.init(step: step, verdict: outcome.verdict))

            if outcome.verdict == .done {
                guard isRead(step) else { return ReplacementOutcome(result: .replaced(by: step), attempts: attempts) }
                // The stale-buffer read found the word; the steps after it replace that word.
                current = replacer.wordBeforeCaret
                replacement = nil
                continue
            }
            if !outcome.fieldUntouched { return ReplacementOutcome(result: .halted(after: step), attempts: attempts) }
            if isRead(step) { return ReplacementOutcome(result: .exhausted, attempts: attempts) }
        }
        return ReplacementOutcome(result: .exhausted, attempts: attempts)
    }

    /// The only step that writes nothing (not even a selection range). P2-51: every other step, including any
    /// added later, counts as a write and takes the claim first.
    private static func isRead(_ step: ReplacementStep) -> Bool {
        if case .axReadBeforeCaret = step { return true }
        return false
    }
}
