// P2-21: Double-Shift convert, flow (c) of 001 §3, on `@TextActor` (001 §2.1). Pure decisions over seams:
// `TextReplacing` (AX + keys), `KeyWatching` (the B3 claim and the finish), a main-actor language switch hook and
// a beep hook, so it is unit-tested with fakes only.
//
// One request:
//   1. Stale or cancelled → nothing. Toggle-only mode → switch the language to the pair's other layout, done.
//      No layout maps → the same silent switch when the buffer is empty (P2-54(a)), else a beep.
//   2. `focusInfo` (AX, 0.25 s per call). A non-empty selection → convert the selection: guess its layout with
//      the instance `guessSource` and retype it on the other one (AX write + read-back → type over).
//   3. No selection → the run (P2-59, 001 §12.3): `.convertRun`. Readable field: one AX read of ≤ 256 UTF-16 units
//      before the caret, `RunBeforeCaret.scan` finds the run (or the `LastRun` record names it, X6), AX write with
//      read-back, and a key fallback only when the AX run is exactly the buffer's text. Unreadable / keysOnly /
//      terminal apps: the whole word buffer by keys (backspace × its graphemes, type its re-rendering).
//      The scan finds nothing, or nothing would change = "nothing to convert": double-Shift just switches the
//      language. A run longer than the window → `.runTooLong`, beep. AX can't read the field (focus unknown) and
//      the buffer is empty → just switch (P2-54(a), owner 2026-11-07).
//   4. `ReplacementChain.run(…, mayWrite: { keyWatcher.claimPosting(gen:) })` (B3, §12 W8): the claim is taken
//      before the first write; a lost claim is `.abandoned`, silent, nothing written.
//   5. Replaced and "Switch language after converting" on → switch to the run's target (X7: the side opposite the
//      scan's S, or opposite the buffer's `renderedIn` on the key path), not "the other one than the current source".
//   6. ALWAYS `finishReplacement(gen:newRendering:bufferAfter:bufferRenderedIn:)`, from a `defer`, for every
//      outcome, so the user's held keys replay at once. The switch runs before the finish, so keys typed during the
//      convert replay in the new language.
//   7. Beep when `outcome.shouldBeep` (refused, notConvertible selection, exhausted, halted, timedOut), the layout
//      isn't in the pair, the maps are missing with a buffer, or the run is too long. Abandoned, stale, cancelled
//      and "nothing to convert" are silent.
//
// Buffer after (001 §12.3 X5 table, as built):
//   - the whole buffer was converted by its strokes (keys, or an AX run equal to the buffer's text):
//       switched     → `newRendering: target, bufferAfter: nil` (keep every word, now in `target`), keepsBuffer
//       not switched → `bufferRenderedIn: target, bufferAfter: nil` (switch off, or the switch failed)
//     so a second double-Shift converts the same strokes straight back.
//   - an AX run that differs from the buffer, a selection, or a halted chain → `bufferAfter: []` (forget it all).
//   - nothing written → `nil, nil`.
//   Never a non-empty `bufferAfter` with `bufferRenderedIn` (asserted here and in the processor).
//
// Undo (X6): after an AX run convert the controller keeps one `LastRun` record (ids and ranges, never text). The
// next double-Shift uses it only while the snapshot says nothing touched the field since that convert
// (`untouchedSinceConvert == record.gen`) AND it re-verifies: same bundle ID, pid and focused element (`CFEqual`),
// record younger than `lastRunMaxAgeNanos`, caret collapsed exactly at `location + length`, the window holds at least
// `length` units, and that tail has no `strong(to)` grapheme, at least one `strong(from)` grapheme and no hard stop.
// Otherwise the record is dropped and the normal scan runs. Every request takes the record out first, so a record
// serves at most the very next double-Shift.
//
// Privacy: text read through AX lives only inside `decide` (the replacer is ended before it returns); the outcome
// and the `LastRun` record hold steps, ids and ranges only. Nothing here logs.

import Foundation

@TextActor final class ConvertController {
    /// Main-actor input-source switch. `keepsBuffer` = the change notification must not reset the tap's buffer:
    /// the finish that follows states the buffer itself (kept re-rendered in `target`, or forgotten).
    /// Returns true when `target` is (now) selected.
    typealias SwitchLanguage = @Sendable (_ target: InputSourceID, _ keepsBuffer: Bool) async -> Bool

    /// P2-59c (X6): the undo record's maximum age. Undo is "double-Shift again right away": the user sees the result
    /// and presses again within a second or two. Changes the tap can't see (dictation, an app's own autocorrect, a
    /// sync from elsewhere) can still land in the field without a key or a click, so the window in which such a
    /// change could be mistaken for our text is kept short; 5 s is generous for a deliberate undo. Past it, the
    /// normal scan runs, which is always safe (it just converts the run it finds).
    static let lastRunMaxAgeNanos: UInt64 = 5_000_000_000

    /// P2-59c (X6): the last AX run convert, as ids and ranges only (never text; checked by a Mirror test).
    struct LastRun {
        /// The convert's generation; usable only while the snapshot's `untouchedSinceConvert` equals it.
        let gen: UInt64
        let bundleID: String
        let processID: Int32
        /// The focused element written to (identity only, compared with `CFEqual`).
        let element: any FocusedElementIdentity
        /// Absolute UTF-16 offset and length of the text written (the run as it is now).
        let location: Int
        let length: Int
        /// The side the written text is on now (the convert's target), and the side it came from.
        let from: PairSide
        let to: PairSide
        /// `clock.nowNanos` when written.
        let madeAtNanos: UInt64
    }

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
    /// P2-59c (X6): the undo record of the last AX run convert, for the next double-Shift only.
    private(set) var lastRun: LastRun?

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
        var finish = Finish()
        defer {
            // P2-59c (X5): a kept, re-rendered buffer is the whole buffer, never new strokes for the current word.
            assert(finish.bufferRenderedIn == nil || finish.bufferAfter?.isEmpty != false,
                   "P2-59: bufferRenderedIn never comes with a non-empty bufferAfter")
            keyWatcher.finishReplacement(gen: request.gen, newRendering: finish.newRendering,
                                         bufferAfter: finish.bufferAfter, bufferRenderedIn: finish.bufferRenderedIn)
        }

        let outcome: ConvertOutcome
        if let last = lastGeneration, request.gen <= last {
            outcome = .noop(.staleGeneration)
        } else {
            lastGeneration = request.gen
            do {
                outcome = try await run(request, layouts: layouts, finish: &finish)
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

    /// What `finishReplacement` gets (all nil: nothing written, the buffer is untouched).
    private struct Finish {
        var newRendering: InputSourceID?
        var bufferAfter: [Stroke]?
        var bufferRenderedIn: InputSourceID?
    }

    private enum Decision {
        /// `keptBuffer`: the whole buffer was converted by its strokes, so it now shows in `target` (X5).
        /// `isRun`: a run convert (not a selection). `record`: the X6 undo record of an AX run write.
        case replaced(target: InputSourceID, step: ReplacementStep, keptBuffer: Bool, isRun: Bool, record: LastRun?)
        case nothingToConvert
        /// P2-54(a): focus unknown and nothing remembered.
        case fieldUnreadable
        case failed(ConvertOutcome.NoopReason, beeps: Bool, textMayHaveChanged: Bool)
    }

    private func run(_ r: ConvertRequest, layouts: LayoutSnapshot?, finish: inout Finish) async throws
        -> ConvertOutcome {
        try Task.checkCancellation()
        // X6: a record serves only the very next double-Shift; this one takes it out whatever it does.
        let record = lastRun
        lastRun = nil
        if r.mode == .toggleOnly { return await toggle(r, because: .toggleMode) }
        guard let layouts, layouts.pair == r.pair else {
            // P2-54(a): nothing remembered and nothing that could convert the field → just switch the language.
            if !r.snapshot.hasRun { return await toggle(r, because: .layoutsUnavailable) }
            beep()
            return .noop(.layoutsUnavailable)
        }
        switch decide(r, layouts: layouts, record: record) {
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case .fieldUnreadable:
            return await toggle(r, because: .fieldUnreadable)
        case let .failed(reason, beeps, textMayHaveChanged):
            if textMayHaveChanged { finish.bufferAfter = [] }
            if beeps { beep() }
            return .noop(reason)
        case let .replaced(target, step, keptBuffer, isRun, newRecord):
            lastRun = newRecord
            // X5: keep every word (re-rendered) or forget them all; never new strokes for one word.
            finish.bufferAfter = keptBuffer ? nil : []
            var switched = false
            if r.switchAfterConvert, !Task.isCancelled {
                // P2-59c: a run convert's finish states the buffer itself (kept, or `[]`), so the change notification
                // must not reset the processor: that reset would also clear `untouchedSinceConvert` and kill the X6
                // undo whenever "switch after converting" is on. A selection keeps the P2-21 behaviour.
                switched = await switchLanguage(target, keptBuffer || isRun)
            }
            if keptBuffer {
                if switched { finish.newRendering = target } else { finish.bufferRenderedIn = target }
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
    private func decide(_ r: ConvertRequest, layouts: LayoutSnapshot, record: LastRun?) -> Decision {
        let replacer = currentReplacer()
        defer { replacer.endReplacement() }
        let focus = replacer.focusInfo(timeout: ReplacementExecutor.axTimeout)

        if let selection = focus?.selection, !selection.isEmpty {
            let request = ReplacementRequest(kind: .convertSelection, bundleID: r.bundleID, snapshot: r.snapshot,
                                             selectionLength: selection.count)
            var target: InputSourceID?
            let outcome = runChain(request, focus: focus, old: selection, gen: r.gen, replacer: replacer,
                                   locateRun: nil) { text in
                guard let c = layouts.convertGuessing(text) else { return nil }
                target = c.target
                return c.text
            }
            guard case .replaced(let step) = outcome.result else { return Self.failure(outcome) }
            guard let target else {   // can't happen: a write only runs after `convert` answered
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            return .replaced(target: target, step: step, keptBuffer: false, isRun: false, record: nil)
        }
        return decideRun(r, layouts: layouts, focus: focus, element: replacer.focusedElement, record: record,
                         replacer: replacer)
    }

    /// P2-59 (001 §12.3 X4–X6): no selection, the run before the caret.
    private func decideRun(_ r: ConvertRequest, layouts: LayoutSnapshot, focus: FocusInfo?,
                           element: (any FocusedElementIdentity)?, record: LastRun?,
                           replacer: any TextReplacing) -> Decision {
        let snap = r.snapshot

        // X5: the buffer's run (every word and the spaces between), in the layout it shows in now.
        var old: String?
        var rendered: (target: InputSourceID, text: String)?
        if snap.hasRun {
            let source = snap.renderedIn ?? r.currentSource
            guard layouts.side(of: source) != nil else {
                return .failed(.notInPair, beeps: true, textMayHaveChanged: false)
            }
            // nil (a dead key, a combining mark): the screen can't be counted, so no key step; AX only.
            if let typed = layouts.typedRun(snap, in: source), let render = layouts.renderRun(snap, from: source) {
                old = typed
                rendered = render
            }
        }
        let request = ReplacementRequest(kind: .convertRun, bundleID: r.bundleID, snapshot: snap,
                                         typedLength: old?.count)

        // X6: the record is a candidate only while nothing touched the field since that convert, in the same app,
        // process and element, and while it is fresh. The window checks follow in `locate`.
        let now = clock.nowNanos
        let usable = record.flatMap { rec -> LastRun? in
            guard snap.untouchedSinceConvert == rec.gen, rec.bundleID == r.bundleID,
                  now >= rec.madeAtNanos, now - rec.madeAtNanos <= Self.lastRunMaxAgeNanos,
                  let element, element.processID == rec.processID, element.isSameElement(as: rec.element)
            else { return nil }
            return rec
        }

        // Captured from the chain's callbacks; local to this call (the text never leaves it).
        var scan: RunBeforeCaret.Scan?
        var located: (location: Int, side: PairSide)?
        var target: InputSourceID?
        var fromBuffer = false
        var writtenUnits = 0

        let locate: (BeforeCaretWindow) -> RunLocation? = { window in
            if let rec = usable, let run = Self.recordedRun(rec, in: window, layouts: layouts) {
                located = (window.location + run.offset, rec.from)
                return run
            }
            // No record, or it no longer matches the field: drop it and scan normally.
            let s = RunBeforeCaret.scan(window, classify: layouts.runClass)
            scan = s
            guard case let .run(run, side) = s else { return nil }
            located = (window.location + run.offset, side)
            return run
        }
        let convert: (String) -> String? = { text in
            // P2-60: scalar equality, not String's canonical equivalence: a precomposed vs decomposed run must not
            // count as "exactly the buffer" (the key path backspaces by the buffer's own count).
            if let old, let rendered, text.unicodeScalars.elementsEqual(old.unicodeScalars) {
                // The buffer's text (keys, or an AX run that is exactly the buffer): convert by its strokes.
                guard rendered.text != old else { return nil }
                fromBuffer = true
                target = rendered.target
                writtenUnits = rendered.text.utf16.count
                return rendered.text
            }
            // An AX run: convert from its side (the scan's S, or the record's `from`).
            guard let side = located?.side, let c = layouts.converter(from: layouts.source(of: side)) else {
                return nil
            }
            let out = c.convert(text).text
            guard !out.isEmpty, out != text else { return nil }
            fromBuffer = false
            target = layouts.source(of: side.other)
            writtenUnits = out.utf16.count
            return out
        }

        let outcome = runChain(request, focus: focus, old: old, gen: r.gen, replacer: replacer, locateRun: locate,
                               convert: convert)
        switch outcome.result {
        case .replaced(let step):
            guard let target, let toSide = layouts.side(of: target) else {   // can't happen (see `convert`)
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            var newRecord: LastRun?
            if case .axWriteSelection = step, let located, let element, let pid = element.processID,
               writtenUnits > 0 {
                newRecord = LastRun(gen: r.gen, bundleID: r.bundleID, processID: pid, element: element,
                                    location: located.location, length: writtenUnits, from: toSide,
                                    to: toSide.other, madeAtNanos: now)
            }
            return .replaced(target: target, step: step, keptBuffer: fromBuffer, isRun: true, record: newRecord)
        case .notConvertible, .refused(.bufferStale):
            return .nothingToConvert
        case .refused(.focusUnknown) where !snap.hasRun:
            return .fieldUnreadable   // P2-54(a)
        case .exhausted where outcome.attempts.allSatisfy({ Self.isRead($0.step) }):
            // The read found no run (or couldn't run and there was no key step).
            if scan == .tooLong { return .failed(.runTooLong, beeps: true, textMayHaveChanged: false) }
            // QA (P2-59c): the read itself failed while the buffer holds words Kytkin couldn't count or type (a dead
            // key, `noUnicode`): "couldn't convert", a beep, as on the key path. Only "read fine, nothing there", or
            // a failed read with nothing remembered (P2-54(a)), just switches.
            if snap.hasRun, outcome.attempts.contains(where: { $0.verdict != .done }) {
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: false)
            }
            return .nothingToConvert
        default:
            return Self.failure(outcome)
        }
    }

    private func runChain(_ request: ReplacementRequest, focus: FocusInfo?, old: String?, gen: UInt64,
                          replacer: any TextReplacing, locateRun: ((BeforeCaretWindow) -> RunLocation?)?,
                          convert: (String) -> String?) -> ReplacementOutcome {
        let plan = ReplacementPlanner.plan(request, caps: capabilities, focus: focus)
        var caps = capabilities
        let keyWatcher = self.keyWatcher
        let outcome = ReplacementChain.run(
            plan, on: replacer, bundleID: request.bundleID, old: old, convert: convert, locateRun: locateRun,
            capabilities: &caps, clock: clock,
            mayWrite: { keyWatcher.claimPosting(gen: gen) })   // B3 (§12 W8): before the first write
        capabilities = caps
        return outcome
    }

    private static func failure(_ outcome: ReplacementOutcome) -> Decision {
        let halted = if case .halted = outcome.result { true } else { false }
        return .failed(.replacement(outcome.result), beeps: outcome.shouldBeep, textMayHaveChanged: halted)
    }

    private func currentReplacer() -> any TextReplacing {
        if let replacer { return replacer }
        let made = makeReplacer()
        replacer = made
        return made
    }

    /// X6: the recorded run, if the window still shows it: the caret exactly at its end, the window holds all of it
    /// (starting on a character boundary), and its text is still on the record's `from` side: at least one
    /// `strong(from)` grapheme, no `strong(to)` grapheme, no hard stop. nil = the record no longer matches.
    static func recordedRun(_ rec: LastRun, in window: BeforeCaretWindow, layouts: LayoutSnapshot) -> RunLocation? {
        let units = window.text.utf16
        guard rec.length > 0, window.location + units.count == rec.location + rec.length,
              units.count >= rec.length else { return nil }
        let offset = units.count - rec.length
        let start = units.index(units.startIndex, offsetBy: offset)
        guard start.samePosition(in: window.text) != nil else { return nil }   // not mid-character
        var hasFrom = false
        for ch in window.text[start...] {
            switch layouts.runClass(of: ch) {
            case .hardStop: return nil
            case .strong(let side) where side == rec.to: return nil
            case .strong: hasFrom = true
            default: break
            }
        }
        return hasFrom ? RunLocation(offset: offset, length: rec.length) : nil
    }

    private static func isRead(_ step: ReplacementStep) -> Bool {
        if case .axReadRunBeforeCaret = step { return true }
        return false
    }
}
