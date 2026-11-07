// P2-21: Double-Shift convert, flow (c) of 001 §3, on `@TextActor` (001 §2.1). Pure decisions over seams:
// `TextReplacing` (AX + keys), `KeyWatching` (the B3 claim and the finish), a main-actor language switch hook and
// a beep hook, so it is unit-tested with fakes only.
//
// One request:
//   1. Stale or cancelled → nothing. Toggle-only mode → switch the language to the pair's other layout, done.
//   2. `focusInfo` (AX, 0.25 s per call). A non-empty selection → convert the selection: guess its layout with
//      the instance `guessSource` and retype it on the other one (AX write + read-back → type over).
//   3. No selection, a valid buffer typed in a pair layout → the last word: the same strokes rendered in the other
//      layout, backspace × (graphemes on screen now) + type.
//   4. No selection, no valid buffer → the stale path (AX read before the caret → AX write). Nothing found there
//      (or nothing either layout types) = "nothing to convert": double-Shift just switches the language.
//   5. `ReplacementChain.run(…, mayWrite: { keyWatcher.claimPosting(gen:) })` (B3, §12 W8): the claim is taken
//      before the first write; a lost claim is `.abandoned`, silent, nothing written.
//   6. Replaced and "Switch language after converting" on → switch to the target (main; the switcher's
//      expected-switch token keeps it out of the learner).
//   7. ALWAYS `finishReplacement(gen:newRendering:bufferAfter:)`, from a `defer`, for every outcome, so the user's
//      held keys replay at once and never wait for the deadline or the 1 s hard cap. The switch runs before the
//      finish, so keys typed during the convert replay in the new language.
//   8. Beep when `outcome.shouldBeep` (refused, notConvertible selection, exhausted, halted, timedOut), or when
//      the layout isn't in the pair. Abandoned, stale and cancelled are silent.
//
// Buffer after (what the tap's word buffer holds once finished):
//   - last word by strokes, switched → `newRendering: target, bufferAfter: strokes` (the same keys, now in the
//     target layout), and the switch is flagged "keeps the buffer" (P2-52 item 7): a second double-Shift converts
//     straight back (001 §3 (c) step 9, the MVP undo).
//   - any other text change (not switched, selection, AX path, halted) → `bufferAfter: []`: the strokes no longer
//     describe what is on screen, so the tap forgets the whole buffer (P2-21 QA: keeping the earlier words let a
//     Backspace make one "current" again over changed text), as after a click.
//   - nothing written → `nil, nil` (the buffer is untouched).
// Undo: 001 defines no Backspace-undo for a manual convert in the MVP (that is P4-8, for auto-fix only). Double-Shift
// again is the undo.
//
// P2-59b (bridge only): the request kind is `.convertRun` and the AX read finds the run with `RunBeforeCaret`;
// a `.tooLong` scan is treated as "nothing to convert" for now. The run flow itself (whole-buffer key path, buffer-
// after table, `LastRun`, `.runTooLong`, switch target) is P2-59c (001 §12.3 X9).
//
// Privacy: text read through AX lives only inside `decide` (the replacer is ended before it returns); the outcome
// holds steps and ids only. Nothing here logs.

import Foundation

@TextActor final class ConvertController {
    /// Main-actor input-source switch. `keepsBuffer` = the tap's buffer was re-rendered into `target` and must survive
    /// the change notification. Returns true when `target` is (now) selected.
    typealias SwitchLanguage = @Sendable (_ target: InputSourceID, _ keepsBuffer: Bool) async -> Bool

    private let keyWatcher: any KeyWatching
    private let clock: any Clock
    private let beep: @Sendable () -> Void
    private let makeReplacer: @TextActor @Sendable () -> any TextReplacing
    private let switchLanguage: SwitchLanguage

    private var replacer: (any TextReplacing)?
    /// Session verdicts + the user's per-app overrides (§12 T5). Never persisted (§12 T6).
    private(set) var capabilities: ReplacementCapabilities
    private var appliedOverrides: [String: MethodHint] = [:]
    /// The newest generation handled. The processor's counter only grows for the app's lifetime (one
    /// KeyStreamProcessor, kept across tap restarts), so an older one is a late, out-of-order request.
    private(set) var lastGeneration: UInt64?
    /// For tests and diagnostics: holds no text.
    private(set) var lastOutcome: ConvertOutcome?

    nonisolated init(keyWatcher: any KeyWatching, clock: any Clock = SystemClock(),
                     capabilities: ReplacementCapabilities = ReplacementCapabilities(),
                     beep: @escaping @Sendable () -> Void,
                     makeReplacer: @escaping @TextActor @Sendable () -> any TextReplacing,
                     switchLanguage: @escaping SwitchLanguage) {
        self.keyWatcher = keyWatcher
        self.clock = clock
        self.capabilities = capabilities
        self.beep = beep
        self.makeReplacer = makeReplacer
        self.switchLanguage = switchLanguage
    }

    // MARK: - Entry points

    /// Handles one double-Shift. Always ends with exactly one `finishReplacement(gen: request.gen, …)`.
    @discardableResult
    func handle(_ request: ConvertRequest, layouts: LayoutSnapshot?) async -> ConvertOutcome {
        var newRendering: InputSourceID?
        var bufferAfter: [Stroke]?
        defer { keyWatcher.finishReplacement(gen: request.gen, newRendering: newRendering, bufferAfter: bufferAfter) }

        let outcome: ConvertOutcome
        if let last = lastGeneration, request.gen <= last {
            outcome = .noop(.staleGeneration)
        } else {
            lastGeneration = request.gen
            do {
                outcome = try await run(request, layouts: layouts, newRendering: &newRendering,
                                        bufferAfter: &bufferAfter)
            } catch {
                outcome = .noop(.cancelled)
            }
        }
        lastOutcome = outcome
        return outcome
    }

    /// Settings → Apps (§12 T5): replaces the user's overrides; removed apps fall back to the seeds.
    func setMethodHintOverrides(_ overrides: [String: MethodHint]) {
        for id in appliedOverrides.keys where overrides[id] == nil { capabilities.setOverride(nil, for: id) }
        for (id, hint) in overrides { capabilities.setOverride(hint, for: id) }
        appliedOverrides = overrides
    }

    // MARK: - Flow

    private enum Decision {
        /// `keptStrokes`: the buffer path, whose strokes now render in `target` (kept only if we switch).
        case replaced(target: InputSourceID, step: ReplacementStep, keptStrokes: [Stroke]?)
        case nothingToConvert
        case failed(ConvertOutcome.NoopReason, beeps: Bool, textMayHaveChanged: Bool)
    }

    private func run(_ r: ConvertRequest, layouts: LayoutSnapshot?, newRendering: inout InputSourceID?,
                     bufferAfter: inout [Stroke]?) async throws -> ConvertOutcome {
        try Task.checkCancellation()
        if r.mode == .toggleOnly { return await toggle(r, because: .toggleMode) }
        guard let layouts, layouts.pair == r.pair else {
            beep()
            return .noop(.layoutsUnavailable)
        }
        switch decide(r, layouts: layouts) {
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case let .failed(reason, beeps, textMayHaveChanged):
            if textMayHaveChanged { bufferAfter = [] }
            if beeps { beep() }
            return .noop(reason)
        case let .replaced(target, step, keptStrokes):
            bufferAfter = []
            guard r.switchAfterConvert, !Task.isCancelled else {
                return .converted(to: target, by: step, switched: false)
            }
            let switched = await switchLanguage(target, keptStrokes != nil)
            if switched, let keptStrokes {
                newRendering = target
                bufferAfter = keptStrokes
            }
            return .converted(to: target, by: step, switched: switched)
        }
    }

    /// Only the input source changes. The switch is not flagged as keeping the buffer: its strokes were typed in the
    /// old layout, so the change notification must reset it.
    private func toggle(_ r: ConvertRequest, because reason: ConvertOutcome.ToggleReason) async -> ConvertOutcome {
        guard let target = r.pair.other(than: r.currentSource) else {
            beep()
            return .noop(.notInPair)
        }
        guard await switchLanguage(target, false) else {
            beep()
            return .noop(.switchFailed)
        }
        return .toggledOnly(to: target, because: reason)
    }

    /// Everything that touches the field, synchronously (no suspension), so no other request can reuse the replacer
    /// in between, and nothing read through AX outlives this call.
    private func decide(_ r: ConvertRequest, layouts: LayoutSnapshot) -> Decision {
        let replacer = currentReplacer()
        defer { replacer.endReplacement() }
        let focus = replacer.focusInfo(timeout: ReplacementExecutor.axTimeout)

        if let selection = focus?.selection, !selection.isEmpty {
            let request = ReplacementRequest(kind: .convertSelection, bundleID: r.bundleID, snapshot: r.snapshot,
                                             selectionLength: selection.count)
            return runChain(request, focus: focus, old: selection, gen: r.gen, replacer: replacer,
                            isLastWord: false, keepableStrokes: nil) { layouts.convertGuessing($0) }
        }

        let snap = r.snapshot
        if snap.isValid, !snap.strokes.isEmpty {
            let source = snap.renderedIn ?? r.currentSource
            guard r.pair.other(than: source) != nil else {
                return .failed(.notInPair, beeps: true, textMayHaveChanged: false)
            }
            if let old = layouts.typed(snap.strokes, in: source),
               let rendered = layouts.render(snap.strokes, from: source) {
                let request = ReplacementRequest(kind: .convertRun, bundleID: r.bundleID, snapshot: snap,
                                                 typedLength: old.count)
                return runChain(request, focus: focus, old: old, gen: r.gen, replacer: replacer,
                                isLastWord: true, keepableStrokes: snap.strokes,
                                locateRun: Self.runLocator(layouts)) { text in
                    // The buffered word converts by its strokes; a word found through AX (a no-Unicode app's
                    // fallback inside the same plan) converts by its text.
                    if text == old { return rendered.text == old ? nil : (source, rendered.target, rendered.text) }
                    return layouts.convertGuessing(text)
                }
            }
            // A stroke typed nothing we can name (dead key): the on-screen text is unknown, use the stale path.
        }

        let request = ReplacementRequest(kind: .convertRun, bundleID: r.bundleID, snapshot: nil)
        return runChain(request, focus: focus, old: nil, gen: r.gen, replacer: replacer, isLastWord: true,
                        keepableStrokes: nil, locateRun: Self.runLocator(layouts)) { layouts.convertGuessing($0) }
    }

    private func runChain(_ request: ReplacementRequest, focus: FocusInfo?, old: String?, gen: UInt64,
                          replacer: any TextReplacing, isLastWord: Bool, keepableStrokes: [Stroke]?,
                          locateRun: ((BeforeCaretWindow) -> RunLocation?)? = nil,
                          convert: (String) -> (source: InputSourceID, target: InputSourceID, text: String)?)
        -> Decision {
        let plan = ReplacementPlanner.plan(request, caps: capabilities, focus: focus)
        var target: InputSourceID?
        var caps = capabilities
        let keyWatcher = self.keyWatcher
        let outcome = ReplacementChain.run(
            plan, on: replacer, bundleID: request.bundleID, old: old,
            convert: { text in
                guard let c = convert(text) else { return nil }
                target = c.target
                return c.text
            },
            locateRun: locateRun,
            capabilities: &caps, clock: clock,
            mayWrite: { keyWatcher.claimPosting(gen: gen) })   // B3 (§12 W8): before the first write
        capabilities = caps

        let result = outcome.result
        switch result {
        case .replaced(let step):
            guard let target else {   // can't happen: a write only runs after `convert` answered
                return .failed(.replacement(result), beeps: true, textMayHaveChanged: true)
            }
            let keeps: [Stroke]? = if case .backspaceAndType = step { keepableStrokes } else { nil }
            return .replaced(target: target, step: step, keptStrokes: keeps)
        case .notConvertible where isLastWord,
             .refused(.bufferStale) where isLastWord:
            return .nothingToConvert
        case .exhausted where isLastWord && outcome.attempts.allSatisfy({ Self.isRead($0.step) }):
            // The stale path read nothing before the caret (start of the field, or right after a space).
            return .nothingToConvert
        case .halted:
            return .failed(.replacement(result), beeps: outcome.shouldBeep, textMayHaveChanged: true)
        default:
            return .failed(.replacement(result), beeps: outcome.shouldBeep, textMayHaveChanged: false)
        }
    }

    private func currentReplacer() -> any TextReplacing {
        if let replacer { return replacer }
        let made = makeReplacer()
        replacer = made
        return made
    }

    /// P2-59b bridge: the run before the caret (001 §12.3 X1). An AX run never holds a grapheme of the other side, so
    /// `convertGuessing` picks the scan's side for it.
    private static func runLocator(_ layouts: LayoutSnapshot) -> (BeforeCaretWindow) -> RunLocation? {
        { window in
            if case .run(let location, _) = RunBeforeCaret.scan(window, classify: layouts.runClass) { return location }
            return nil
        }
    }

    private static func isRead(_ step: ReplacementStep) -> Bool {
        if case .axReadRunBeforeCaret = step { return true }
        return false
    }
}
