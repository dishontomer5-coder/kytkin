// P2-21: Double-Shift convert, flow (c) of 001 §3, on `@TextActor` (001 §2.1). Pure decisions over seams:
// `TextReplacing` (AX + keys), `KeyWatching` (the B3 claim and the finish), a main-actor language switch hook and
// a beep hook, so it is unit-tested with fakes only.
//
// One request:
//   1. Stale or cancelled → nothing. Toggle-only mode → switch the language to the pair's other layout, done.
//      No layout maps → the same silent switch when the buffer is empty (P2-54(a)), else a beep.
//   2. `focusInfo` (AX, 0.25 s per call). A non-empty selection → convert the selection: guess its layout with
//      the instance `guessSource` and retype it on the other one (AX write + read-back → type over).
//   3. No selection → `.convertRun`. P3-35 (owner 2026-11-11, 001 §12.3 X11): in a readable field, the whole text box:
//      one AX read of the field (≤ 16,384 UTF-16 units, else a window around the caret), `BoxConversion.plan` turns
//      every letter of the caret-side language anywhere in it into the other language, one AX write of the range from the first to the last changed
//      character with read-back, the caret put back where it was, and a key fallback only when that range ends at
//      the caret and is exactly the buffer's text. (P2-59/P3-33: was the run before the caret.) Unreadable / keysOnly /
//      terminal apps: the whole word buffer by keys (backspace × its graphemes, type its re-rendering); P3-33: that
//      is everything typed since the last Return/Enter, Tab, ⌥Space, click or focus change, ≤ 512 keys.
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
//     so a second double-Shift converts the same strokes to the other language (P3-40: what a fresh convert of that
//     text would give, the strokes keep capitals exact).
//   - an AX write that differs from the buffer (the whole box), a selection, or a halted chain →
//     `bufferAfter: []` (forget it all).
//   - nothing written → `nil, nil`.
//   Never a non-empty `bufferAfter` with `bufferRenderedIn` (asserted here and in the processor).
//
// P3-40 (owner 2026-11-11, plan.md P3-40; 001 §12.3 X13): **no undo**. A second double-Shift is a fresh convert of
// the whole box (or the clipboard copy, or the kept buffer) to the other language: `1 2 1` → `2 2 2` → `1 1 1`. Undo is
// the app's own ⌘Z. The P2-59c/P3-35/P3-37 undo records (`LastRun`, `ClipUndo`: the replaced text, a fingerprint, the
// `untouchedSinceConvert` / `.undoTouched` / `forgetUndo` plumbing) are gone, so no text outlives a request.
//
// P3-37 (owner 2026-11-11, 001 §12.3 X12):
//   (a) Nothing remembered (empty buffer) and nothing written → double-Shift just switches the language, whatever the
//       reason (P2-54(a)): a refused plan (a focus read that looks secure or composing, as Chromium/Electron fields
//       can after a click or an app switch; no method), or an unreadable app's chain that wrote nothing. It used to
//       beep and not switch for every reason but "focus unknown" and "read found nothing".
//   (b) Terminals: a buffer kept across a click or an app switch (`WordSnapshot.crossedFocus`) is used only while the
//       focused element is the one it started in (`anchorTerminalBuffer`); otherwise it is forgotten and double-Shift
//       just switches. Only the current line is ever converted (the buffer ends at every Return, Shift+Return too).
//   (c) The clipboard convert (`ClipboardConvert`) in apps whose text box can't be read through AX and that are not
//       terminals, not secure, not composing, not "Keys only" by the user, with the setting on and a pair whose ⌘A/⌘C/⌘V
//       keys are safe: ⌘A ⌘C, convert the box with `BoxConversion` (direction: the remembered buffer's language, else
//       the box's last letter, as if the caret were at its end), paste it with ⌘V, put the clipboard back after the
//       finish. Empty box / no copy →
//       the remembered buffer by keys, else just switch. P3-40: double-Shift again converts the box again (no undo).
//   P3-40 (b): a selection AX reports in such an app is copied with ⌘C (no ⌘A) and pasted over, not typed over:
//       Chromium's `AXSelectedText` can drop the line breaks between paragraphs, so typing it over joined the lines.
//
// P3-42 (001 §12.3 X15): in a Chromium/Electron app (`FieldFamily.chromiumAX`: Chrome, Edge, Brave, Arc, Vivaldi, Opera,
//   Slack, Discord, Teams; not VS Code, not terminals, not the user's own method choice, not whole-document web apps, not
//   a focused address bar), a double-Shift first tries `ChromiumAXConvert`: read the box (or the selection) through
//   `AXValue`, convert it, select each changed piece with `AXSelectedTextRange`, read it back, type over it, verify.
//   Only changed letters are retyped, so Slack bold, links and mentions around them stay. Anything it can't vouch for
//   before typing (`.unavailable`) → the P3-37 / P3-40 path exactly as before (clipboard, else keys). Kill switch:
//   `ChromiumAXConvert.isEnabled` and the `KytkinDisableChromiumAX` user default (`chromiumAXEnabled`).
//
// Privacy: text read through AX lives only inside `decide` (the replacer is ended before it returns), clipboard text
// only inside `runClipboard`; the outcome holds steps only. P3-40: nothing is kept for an undo. Nothing here logs.

import Foundation

@TextActor final class ConvertController {
    /// Main-actor input-source switch. `keepsBuffer` = the change notification must not reset the tap's buffer:
    /// the finish that follows states the buffer itself (kept re-rendered in `target`, or forgotten).
    /// Returns true when `target` is (now) selected.
    typealias SwitchLanguage = @Sendable (_ target: InputSourceID, _ keepsBuffer: Bool) async -> Bool

    /// P3-37 (c): one clipboard convert, decided synchronously in `decide` and run (with its bounded waits) in `run`.
    private struct ClipJob {
        let source: ClipboardConvert.Source
        /// The focused element at the start: every shortcut goes only while it still has focus.
        let element: any FocusedElementIdentity
        /// The remembered buffer's side (the box's direction), nil = the box's last letter.
        let direction: PairSide?
        /// P3-40 (b): the selection as AX reported it (`.copiedSelection` only), to check the ⌘C copy against.
        let axSelection: String?
        /// P3-37 QA: the text may hold line breaks (and other control characters). True only in an app seeded as
        /// keys-only (Slack, Chrome…); an unseeded app could be a terminal Kytkin doesn't know (an Electron one whose
        /// xterm.js box reads as an AXTextArea), where a pasted line break without bracketed paste runs a command.
        let mayPasteLineBreaks: Bool
    }

    /// P3-42: one Chromium/Electron AX convert, decided synchronously in `decide` and run (it waits) in `run`.
    private struct ChromiumJob {
        let source: ChromiumAXConvert.Source
        /// The focused element at the start: every piece is written only while it still has focus.
        let element: any FocusedElementIdentity
    }

    private let keyWatcher: any KeyWatching
    private let clock: any Clock
    private let beep: @Sendable () -> Void
    private let makeReplacer: @TextActor @Sendable () -> any TextReplacing
    private let switchLanguage: SwitchLanguage
    /// P3-37 (c): the clipboard convert's seams (live: NSPasteboard + CGEvent); nil = never use the clipboard.
    private let makeClipboard: (@TextActor @Sendable () -> ClipboardConvert?)?
    /// P3-42: the Chromium/Electron AX convert's seams (live: AX + CGEvent); nil = never used.
    private let makeChromiumAX: (@TextActor @Sendable () -> ChromiumAXConvert?)?
    /// P3-42: the kill switch (`ChromiumAXConvert.isEnabled` and the hidden user default, read by the composition root).
    private let chromiumAXEnabled: Bool

    private var replacer: (any TextReplacing)?
    private var clipboard: ClipboardConvert?
    private var chromiumAX: ChromiumAXConvert?
    /// P3-37 (c): the user's clipboard, to put back after this request's finish (bounded).
    private var pendingRestore: ClipboardConvert.PendingRestore?
    /// P3-37 (b): the focused element a terminal's buffer started in.
    /// P3-41: `element` nil = AX named no focused element when the buffer started (Ghostty-based terminals may not).
    private var terminalAnchor: (epoch: UInt64, element: (any FocusedElementIdentity)?)?
    /// P3-37: the generation whose B3 claim this controller holds (the clipboard and a key fallback share one claim).
    private var claimedGen: UInt64?
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
                     switchLanguage: @escaping SwitchLanguage,
                     makeClipboard: (@TextActor @Sendable () -> ClipboardConvert?)? = nil,
                     makeChromiumAX: (@TextActor @Sendable () -> ChromiumAXConvert?)? = nil,
                     chromiumAXEnabled: Bool = ChromiumAXConvert.isEnabled) {
        self.keyWatcher = keyWatcher
        self.clock = clock
        self.capabilities = capabilities
        self.beep = beep
        self.makeReplacer = makeReplacer
        self.switchLanguage = switchLanguage
        self.makeClipboard = makeClipboard
        self.makeChromiumAX = makeChromiumAX
        self.chromiumAXEnabled = chromiumAXEnabled
    }

    // MARK: - Entry points

    /// Handles one double-Shift. Always ends with exactly one `finishReplacement(gen: request.gen, …)`.
    /// P3-37 (c): after that finish (so held keys replay at once), the user's clipboard is put back (bounded wait).
    @discardableResult
    func handle(_ request: ConvertRequest, layouts: LayoutSnapshot?) async -> ConvertOutcome {
        let outcome = await handleAndFinish(request, layouts: layouts)
        if let pending = pendingRestore {
            pendingRestore = nil
            await clipboard?.finish(pending)
        }
        return outcome
    }

    private func handleAndFinish(_ request: ConvertRequest, layouts: LayoutSnapshot?) async -> ConvertOutcome {
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
        /// `isRun`: a run convert (not a selection).
        case replaced(target: InputSourceID, step: ReplacementStep, keptBuffer: Bool, isRun: Bool)
        case nothingToConvert
        /// P2-54(a): focus unknown and nothing remembered.
        case fieldUnreadable
        case failed(ConvertOutcome.NoopReason, beeps: Bool, textMayHaveChanged: Bool)
        /// P3-37 (c): run the clipboard convert (it waits, so it runs in `run`, not in `decide`).
        case clipboard(ClipJob)
        /// P3-42: run the Chromium/Electron AX convert (it waits too).
        case chromiumAX(ChromiumJob)
    }

    private func run(_ request: ConvertRequest, layouts: LayoutSnapshot?, finish: inout Finish) async throws
        -> ConvertOutcome {
        try Task.checkCancellation()
        claimedGen = nil
        var r = request
        if r.mode == .toggleOnly { return await toggle(r, because: .toggleMode) }
        // P3-37 (b): a terminal buffer kept across a click or an app switch, in another window / tab / split now (or
        // focus unknown): forget it, so its keys never go to the wrong place.
        if r.snapshot.crossedFocus, r.snapshot.hasRun, !terminalBufferStillFocused(r.snapshot) {
            r = r.with(snapshot: r.snapshot.emptied())
            finish.bufferAfter = []
        }
        guard let layouts, layouts.pair == r.pair else {
            // P2-54(a): nothing remembered and nothing that could convert the field → just switch the language.
            if !r.snapshot.hasRun { return await toggle(r, because: .layoutsUnavailable) }
            beep()
            return .noop(.layoutsUnavailable)
        }
        let decision = decide(r, layouts: layouts, allowClipboard: r.useClipboard, allowChromiumAX: true)
        return await apply(decision, r, layouts: layouts, finish: &finish)
    }

    private func apply(_ decision: Decision, _ r: ConvertRequest, layouts: LayoutSnapshot,
                       finish: inout Finish) async -> ConvertOutcome {
        switch decision {
        case .clipboard(let job):
            return await runClipboard(job, r, layouts: layouts, finish: &finish)
        case .chromiumAX(let job):
            return await runChromiumAX(job, r, layouts: layouts, finish: &finish)
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case .fieldUnreadable:
            return await toggle(r, because: .fieldUnreadable)
        case let .failed(reason, beeps, textMayHaveChanged):
            if textMayHaveChanged { finish.bufferAfter = [] }
            if beeps { beep() }
            return .noop(reason)
        case let .replaced(target, step, keptBuffer, isRun):
            // X5: keep every word (re-rendered) or forget them all; never new strokes for one word.
            finish.bufferAfter = keptBuffer ? nil : []
            var switched = false
            if r.switchAfterConvert, !Task.isCancelled {
                // P2-59c: a run convert's finish states the buffer itself (kept, or `[]`), so the change notification
                // need not reset the processor (P3-40: there is no undo to keep any more; the flag stays so this
                // switch's notification never resets mid-request). A selection keeps the P2-21 behaviour.
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
    private func decide(_ r: ConvertRequest, layouts: LayoutSnapshot, allowClipboard: Bool,
                        allowChromiumAX: Bool) -> Decision {
        let replacer = currentReplacer()
        defer { replacer.endReplacement() }
        let focus = replacer.focusInfo(timeout: ReplacementExecutor.axTimeout)
        // The chain ends the replacement (dropping the element) when it returns: keep the identity for P3-37's job.
        let element = replacer.focusedElement

        // P3-37 (a): a terminal's selection is display only (P2-36: never typed over). It used to beep and not even
        // switch; now it is ignored: the remembered line converts by keys, or double-Shift just switches.
        let terminalSelection = capabilities.method(for: r.bundleID) == .terminal
        if let selection = focus?.selection, !selection.isEmpty, !terminalSelection {
            // P3-42: a Chromium/Electron web box: select and type over only the changed pieces of the selection.
            if allowChromiumAX, let job = chromiumJob(r, focus: focus, element: element, source: .selection) {
                return .chromiumAX(job)
            }
            // P3-40 (b): in an app whose box AX can't read (Slack, Chrome…), AX's selected text may have lost the line
            // breaks (Chromium can drop them between paragraphs), so typing it over joined the lines. Copy the selection
            // itself with ⌘C (no ⌘A), check it against the AX text, convert, paste over it.
            if allowClipboard, let f = focus,
               !ReplacementPlanner.writesSelection(bundleID: r.bundleID, caps: capabilities, focus: f),
               let job = clipJob(r, layouts: layouts, focus: focus, element: element, source: .copiedSelection,
                                 direction: nil, axSelection: selection) {
                return .clipboard(job)
            }
            let request = ReplacementRequest(kind: .convertSelection, bundleID: r.bundleID, snapshot: r.snapshot,
                                             selectionLength: selection.count)
            var target: InputSourceID?
            let outcome = runChain(request, focus: focus, old: selection, gen: r.gen, replacer: replacer,
                                   locateField: nil) { text in
                guard let c = layouts.convertGuessing(text) else { return nil }
                target = c.target
                return c.text
            }
            // P3-40 (b): the P3-37 (c) paste of AX's selected text (a line break in it) is gone: the ⌘C copy above
            // replaced it, since AX's text is what lost the line breaks.
            guard case .replaced(let step) = outcome.result else { return Self.failure(outcome) }
            guard let target else {   // can't happen: a write only runs after `convert` answered
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            return .replaced(target: target, step: step, keptBuffer: false, isRun: false)
        }
        return decideRun(r, layouts: layouts, focus: focus, element: element, allowClipboard: allowClipboard,
                         allowChromiumAX: allowChromiumAX, replacer: replacer)
    }

    /// P2-59 (001 §12.3 X4–X6): no selection, the run before the caret.
    private func decideRun(_ r: ConvertRequest, layouts: LayoutSnapshot, focus: FocusInfo?,
                           element: (any FocusedElementIdentity)?, allowClipboard: Bool, allowChromiumAX: Bool,
                           replacer: any TextReplacing) -> Decision {
        let snap = r.snapshot

        // P3-42: a Chromium/Electron web box AX can read but not write: the whole box through `ChromiumAXConvert`
        // first (before the clipboard; the clipboard switch is not needed for it).
        if allowChromiumAX, let f = focus, !ReplacementPlanner.readsField(bundleID: r.bundleID, caps: capabilities, focus: f),
           let job = chromiumJob(r, focus: focus, element: element, source: .box) {
            return .chromiumAX(job)
        }

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

        // P3-37 (c): an app whose box AX can't read: the clipboard first (the whole box, every line), the remembered
        // buffer only if that finds nothing. Direction: the buffer's language when it holds a letter of it.
        if allowClipboard, let f = focus,
           !ReplacementPlanner.readsField(bundleID: r.bundleID, caps: capabilities, focus: f) {
            let source = snap.renderedIn ?? r.currentSource
            let direction = layouts.side(of: source).flatMap { side in
                old?.contains { $0.isLetter && layouts.runClass(of: $0) == .strong(side) } == true ? side : nil
            }
            if let job = clipJob(r, layouts: layouts, focus: focus, element: element, source: .box,
                                 direction: direction, axSelection: nil) {
                return .clipboard(job)
            }
        }

        // Captured from the chain's callbacks; local to this call (the text never leaves it).
        var box: BoxConversion.Result?
        var plan: BoxConversion.Plan?
        /// P3-35: the buffer's strokes may stand for the range only when it ends at the caret (keys: no read at all).
        var bufferMayApply = true
        var target: InputSourceID?
        var fromBuffer = false

        // P3-35 (X11): the whole text box. P3-40: every time, also right after a convert (no undo record).
        let locate: (FieldWindow) -> FieldEdit? = { window in
            let result = BoxConversion.plan(window, classify: layouts.runClass) { side, grapheme in
                layouts.converter(from: layouts.source(of: side))?.convert(grapheme).text ?? grapheme
            }
            box = result
            guard case .convert(let p) = result else { return nil }
            plan = p
            bufferMayApply = window.location + p.edit.offset + p.edit.length == window.caret
            return p.edit
        }
        let convert: (String) -> String? = { text in
            // P2-60: scalar equality, not String's canonical equivalence: a precomposed vs decomposed run must not
            // count as "exactly the buffer" (the key path backspaces by the buffer's own count).
            if bufferMayApply, let old, let rendered, text.unicodeScalars.elementsEqual(old.unicodeScalars) {
                // The buffer's text (keys, or an AX range that is exactly the buffer): convert by its strokes.
                guard rendered.text != old else { return nil }
                fromBuffer = true
                target = rendered.target
                return rendered.text
            }
            // The whole box: the plan's text for the range it named.
            guard let p = plan else { return nil }
            fromBuffer = false
            target = layouts.source(of: p.side.other)
            return p.text
        }

        let outcome = runChain(request, focus: focus, old: old, gen: r.gen, replacer: replacer, locateField: locate,
                               convert: convert)
        // P3-41 (cmux): a terminal whose AX facts got in the way of the key step converts the buffer by keys anyway, or
        // at least switches (never a silent nothing or a beep with no switch).
        if capabilities.method(for: r.bundleID) == .terminal, let decision = terminalFallback(
            outcome, r, focus: focus, old: old, rendered: rendered, replacer: replacer) {
            return decision
        }
        switch outcome.result {
        case .replaced(let step):
            guard let target else {   // can't happen (see `convert`)
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            return .replaced(target: target, step: step, keptBuffer: fromBuffer, isRun: true)
        case .notConvertible, .refused(.bufferStale):
            return .nothingToConvert
        case .refused(.focusUnknown) where !snap.hasRun:
            return .fieldUnreadable   // P2-54(a)
        case .refused where !snap.hasRun:
            // P3-37 (a): nothing remembered and nothing tried (a focus that reads as secure or composing, no method):
            // just switch, as P2-54(a) says. It beeped before, which is the "doesn't even switch" the owner saw.
            return .fieldUnreadable
        case .exhausted where outcome.attempts.allSatisfy({ Self.isRead($0.step) }):
            // The read found nothing to convert (or couldn't run and there was no key step).
            if box == .tooLong { return .failed(.runTooLong, beeps: true, textMayHaveChanged: false) }
            // QA (P2-59c): the read itself failed while the buffer holds words Kytkin couldn't count or type (a dead
            // key, `noUnicode`): "couldn't convert", a beep, as on the key path. Only "read fine, nothing there", or
            // a failed read with nothing remembered (P2-54(a)), just switches.
            if snap.hasRun, outcome.attempts.contains(where: { $0.verdict != .done }) {
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: false)
            }
            return .nothingToConvert
        case .exhausted where !snap.hasRun && !outcome.attempts.contains(where: { Self.isAXWrite($0.step) }),
             .timedOut where !snap.hasRun && !outcome.attempts.contains(where: { Self.isAXWrite($0.step) }):
            return .fieldUnreadable   // P3-37 (a): an unreadable app's chain that wrote nothing
        default:
            return Self.failure(outcome)
        }
    }

    /// P3-41 (owner 2026-11-11, cmux): the terminal key path needs no AX text, but the chain still asks AX three things
    /// first: is there a focused element (`focusUnknown`), does it look secure or composing (a subrole or marked-range
    /// read that *fails* counts as both, P2-49 item 6 / R5), and is the focus still the element `focusInfo` read
    /// (P2-49 item 3, `CFEqual`). A Ghostty-based terminal can fail each of them: no AX focus, error answers, or a fresh
    /// element on every read. Before P3-37 cmux was unseeded (`.auto`); P3-37 seeded it `.terminal`, and with a buffer
    /// any of these refusals beeped and did not even switch. In a terminal:
    ///   - AX said nothing it could vouch for (refused: focus unknown / looks secure / composing; or the chain ran out
    ///     with nothing posted, e.g. the P2-49 same-element check failed): post the buffer's keys without the AX checks, if the focus AX names (if
    ///     any) still belongs to the request's process. A real secure prompt is covered by Secure Input (the request is
    ///     then toggle-only and never gets here); a real `AXSecureTextField` role still refuses.
    ///   - Anything else that wrote nothing: just switch the language (the buffer's keys were typed in the old layout;
    ///     the switch forgets them).
    /// Returns nil to let the normal outcome handling run (converted, partly posted, a role-secure field…).
    private func terminalFallback(_ outcome: ReplacementOutcome, _ r: ConvertRequest, focus: FocusInfo?, old: String?,
                                  rendered: (target: InputSourceID, text: String)?,
                                  replacer: any TextReplacing) -> Decision? {
        switch outcome.result {
        case .replaced, .halted, .abandoned: return nil
        case .refused(let why):
            if focus?.role == FocusInfo.secureTextFieldRole { return nil }   // a real password field: never keys
            // P3-41 QA: "looks secure / composing" may be skipped only when a failed read alone said so. A secure
            // *subrole* (NSSecureTextField reads as role AXTextField, subrole AXSecureTextField) or a real marked
            // range (an IME composing: Backspace would eat the composition) refuses, as everywhere else.
            if why == .secureField || why == .composing, focus?.fromFailedRead != true { return nil }
            guard why == .focusUnknown || why == .secureField || why == .composing else {
                return r.snapshot.hasRun ? .fieldUnreadable : nil
            }
        case .exhausted, .timedOut:
            break   // by definition nothing was written or posted (ReplacementOutcome)
        case .notConvertible:
            return nil
        }
        guard r.snapshot.hasRun else { return .fieldUnreadable }
        guard let old, let rendered, rendered.text != old else { return .fieldUnreadable }
        // The focus AX names now, if any, must be in the terminal the request came from. P3-41 QA: so must the focused
        // application, which AX names even where it names no focused element (an app that came to the front between
        // the double-Shift and now, before main's context change reset the request); and with no pid for the request
        // there is nothing to compare: no keys.
        guard let pid = r.processID else { return .fieldUnreadable }
        if let now = replacer.currentFocusedElement(timeout: ReplacementExecutor.axTimeout)?.processID, now != pid {
            return .fieldUnreadable
        }
        if let app = replacer.focusedApplicationPID(timeout: ReplacementExecutor.axTimeout), app != pid {
            return .fieldUnreadable
        }
        guard claim(r.gen) else { return .failed(.replacement(.abandoned), beeps: false, textMayHaveChanged: false) }
        let count = old.count
        let result = replacer.postTerminalKeys(count: count, new: rendered.text)
        switch result.verdict {
        case .done:
            return .replaced(target: rendered.target, step: .backspaceAndType(count: count), keptBuffer: true,
                             isRun: true)
        default:
            return result.fieldUntouched ? .fieldUnreadable
                : .failed(.replacement(.halted(after: .backspaceAndType(count: count))), beeps: true,
                          textMayHaveChanged: true)
        }
    }

    private func runChain(_ request: ReplacementRequest, focus: FocusInfo?, old: String?, gen: UInt64,
                          replacer: any TextReplacing, locateField: ((FieldWindow) -> FieldEdit?)?,
                          convert: (String) -> String?) -> ReplacementOutcome {
        let plan = ReplacementPlanner.plan(request, caps: capabilities, focus: focus)
        var caps = capabilities
        let outcome = ReplacementChain.run(
            plan, on: replacer, bundleID: request.bundleID, old: old, convert: convert, locateField: locateField,
            capabilities: &caps, clock: clock,
            mayWrite: { claim(gen) })   // B3 (§12 W8): before the first write
        capabilities = caps
        return outcome
    }

    /// B3: the claim, taken once per generation (P3-37: a key fallback after a clipboard attempt reuses it).
    private func claim(_ gen: UInt64) -> Bool {
        if claimedGen == gen { return true }
        guard keyWatcher.claimPosting(gen: gen) else { return false }
        claimedGen = gen
        return true
    }

    // MARK: - P3-37

    /// P3-37 (c): a clipboard job, or nil when the clipboard may not be used here.
    private func clipJob(_ r: ConvertRequest, layouts: LayoutSnapshot, focus: FocusInfo?,
                         element: (any FocusedElementIdentity)?, source: ClipboardConvert.Source,
                         direction: PairSide?, axSelection: String?) -> ClipJob? {
        guard makeClipboard != nil, !r.inAddressBar, let f = focus, let element, !f.isSecure,
              f.role != FocusInfo.secureTextFieldRole, !f.hasMarkedText, layouts.clipboardShortcutsAreSafe,
              // P3-37 QA: ⌘ + key 0 / 8 / 9 is read in the layout in front: one outside the pair is unchecked.
              layouts.side(of: r.currentSource) != nil
        else { return nil }
        // Never in a terminal (bracketed paste, the prompt), a remote desktop or VM, or an app the user set to "Off"
        // or to "Keys only" (their choice means keys and nothing else).
        let mayPasteLineBreaks: Bool
        switch capabilities.method(for: r.bundleID) {
        case .keysOnly:   // Chromium / Electron: AX may be off, so the role says nothing; the seed vouches for it
            mayPasteLineBreaks = true
        case .auto, .preferPaste:
            mayPasteLineBreaks = false   // P3-37 QA
            // Any other app: only a real text box. ⌘A in a list, table or file browser selects items, and ⌘V could
            // paste over all of them (Numbers, Finder).
            guard let role = f.role, Self.clipboardTextRoles.contains(role) else { return nil }
        case .terminal, .noUnicode, .disabled: return nil
        }
        if capabilities.override(for: r.bundleID) == .keysOnly { return nil }
        // Editors: ⌘A is the whole file and the window may hold a terminal (a pasted line break could run a command).
        if ReplacementCapabilities.isEditor(r.bundleID) { return nil }
        return ClipJob(source: source, element: element, direction: direction, axSelection: axSelection,
                       mayPasteLineBreaks: mayPasteLineBreaks)
    }

    /// P3-37 (c): the AX roles of a text box, for apps not seeded as keys-only.
    static let clipboardTextRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    private func currentClipboard() -> ClipboardConvert? {
        if let clipboard { return clipboard }
        clipboard = makeClipboard?()
        return clipboard
    }

    private func runClipboard(_ job: ClipJob, _ r: ConvertRequest, layouts: LayoutSnapshot,
                              finish: inout Finish) async -> ConvertOutcome {
        guard let cb = currentClipboard() else { return await fallBack(r, layouts: layouts, finish: &finish) }
        var target: InputSourceID?
        let convert: (String) -> ClipboardConvert.Conversion = { text in
            // P3-40 (b): the copy must be the selection AX reported. Only the visible characters are compared: AX may
            // have dropped or changed the line breaks and spaces (that is why the copy is used).
            if case .copiedSelection = job.source, let ax = job.axSelection,
               !Self.sameVisibleText(text, ax) { return .mismatch }
            // P3-37 QA: in an unseeded app a line break (or any control character) is never pasted (ClipJob).
            if !job.mayPasteLineBreaks, ReplacementPlanner.containsUnsafeCharacter(text) { return .unsafe }
            switch job.source {
            case .copiedSelection:
                // P3-40 QA: the same cap as the box (a huge selection would be a slow convert and paste).
                guard text.utf16.count <= ReplacementPlanner.maxFieldReadChars else { return .tooLong }
                guard let c = layouts.convertGuessing(text), c.text != text else { return .nothing }
                target = c.target
                return .replace(c.text)
            case .box:
                guard text.utf16.count <= ReplacementPlanner.maxFieldReadChars else { return .tooLong }
                let window = FieldWindow(text: text, location: 0, caret: text.utf16.count, reachesFieldStart: true,
                                         reachesFieldEnd: true)
                let result = BoxConversion.plan(window, classify: layouts.runClass, direction: job.direction) {
                    side, grapheme in
                    layouts.converter(from: layouts.source(of: side))?.convert(grapheme).text ?? grapheme
                }
                switch result {
                case .nothing: return .nothing
                case .tooLong: return .tooLong
                case .convert(let p):
                    let units = Array(text.utf16)
                    let head = String(decoding: units[..<p.edit.offset], as: UTF16.self)
                    let tail = String(decoding: units[(p.edit.offset + p.edit.length)...], as: UTF16.self)
                    target = layouts.source(of: p.side.other)
                    return .replace(head + p.text + tail)
                }
            }
        }
        let replacer = currentReplacer()
        let element = job.element
        let focusIsSame = {
            replacer.currentFocusedElement(timeout: ReplacementExecutor.axTimeout)?.isSameElement(as: element) ?? false
        }
        let gen = r.gen
        let (result, pending) = await cb.run(job.source, convert: convert, focusIsSame: focusIsSame,
                                             mayWrite: { self.claim(gen) })
        pendingRestore = pending
        switch result {
        case .pasted:
            guard let target else {   // can't happen: pasted after `convert`
                finish.bufferAfter = []
                beep()
                return .noop(.replacement(.halted(after: .pasteboard)))
            }
            // The caret is at the end of the box (or of the pasted selection) now, not where the buffer ended: forget
            // the buffer (X5 table). P3-40: nothing kept for an undo; double-Shift again converts the box again.
            finish.bufferAfter = []
            var switched = false
            if r.switchAfterConvert, !Task.isCancelled {
                // keepsBuffer: the finish forgets the buffer itself (as for an AX run convert).
                switched = await switchLanguage(target, true)
            }
            return .converted(to: target, by: .pasteboard, switched: switched)
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case .tooLong:
            beep()
            return .noop(.runTooLong)
        case .unsafeText:   // P3-37 QA
            beep()
            return .noop(.replacement(.refused(.unsafeSelection)))
        case .selectionMismatch:   // P3-40 (b): ⌘C copied something else than the selection AX reported
            beep()
            return .noop(.replacement(.refused(.selectionUnreadable)))
        case .boxEmpty where job.source == .copiedSelection:
            // P3-40 (b): ⌘C copied nothing; only ⌘C was posted, so the selection is still there. Convert it the old way
            // (AX write / type over the AX text, one line only), all Kytkin can do without a copy.
            return await fallBack(r, layouts: layouts, finish: &finish)
        case .boxEmpty where r.snapshot.hasRun:
            // P3-37 QA: ⌘A (and the Right arrow that dropped its selection) were posted, so the caret is at the end of
            // the box, or one character further right if ⌘A did nothing: not where the remembered buffer ends. Typing
            // the buffer by keys now would backspace over the wrong text. Forget it and beep.
            finish.bufferAfter = []
            beep()
            return .noop(.replacement(.exhausted))
        case .boxEmpty, .unavailable:
            // `.unavailable`: nothing was posted (no snapshot, the first event refused), so the caret is where it was.
            return await fallBack(r, layouts: layouts, finish: &finish)
        case .abandoned:
            return .noop(.replacement(.abandoned))
        case .timedOut:
            finish.bufferAfter = []
            beep()
            return .noop(.replacement(.timedOut))
        case .focusChanged, .failed:
            finish.bufferAfter = []
            beep()
            return .noop(.replacement(.halted(after: .pasteboard)))
        }
    }

    /// P3-37 (c): the clipboard found nothing to copy (or couldn't start): the remembered buffer by keys, else switch.
    private func fallBack(_ r: ConvertRequest, layouts: LayoutSnapshot, finish: inout Finish) async -> ConvertOutcome {
        let decision = decide(r, layouts: layouts, allowClipboard: false, allowChromiumAX: false)
        return await apply(decision, r, layouts: layouts, finish: &finish)
    }

    // MARK: - P3-42

    /// P3-42: a Chromium/Electron AX job, or nil when the path may not be used here.
    private func chromiumJob(_ r: ConvertRequest, focus: FocusInfo?, element: (any FocusedElementIdentity)?,
                             source: ChromiumAXConvert.Source) -> ChromiumJob? {
        guard chromiumAXEnabled, makeChromiumAX != nil, r.allowsChromiumAX, !r.inAddressBar,
              capabilities.family(for: r.bundleID) == .chromiumAX,
              let f = focus, let element, !f.isSecure, f.role != FocusInfo.secureTextFieldRole, !f.hasMarkedText,
              f.selRangeSettable, let role = f.role, Self.clipboardTextRoles.contains(role)
        else { return nil }
        return ChromiumJob(source: source, element: element)
    }

    private func currentChromiumAX() -> ChromiumAXConvert? {
        if let chromiumAX { return chromiumAX }
        chromiumAX = makeChromiumAX?()
        return chromiumAX
    }

    /// P3-42: runs the job; `.unavailable` (nothing typed, the selection put back) → the P3-37 / P3-40 path as before.
    private func runChromiumAX(_ job: ChromiumJob, _ r: ConvertRequest, layouts: LayoutSnapshot,
                               finish: inout Finish) async -> ConvertOutcome {
        guard let ax = currentChromiumAX() else { return await fallBackFromChromium(r, layouts: layouts, finish: &finish) }
        var target: InputSourceID?
        let plan: (ChromiumAXConvert.Read) -> ChromiumAXConvert.Planned = { read in
            switch job.source {
            case .selection:
                let units = Array(read.text.utf16)
                let sel = read.selection
                let text = String(decoding: units[sel.location..<sel.end], as: UTF16.self)
                guard let whole = layouts.convertGuessing(text) else { return .nothing }
                guard let converter = layouts.converter(from: whole.source) else { return .unavailable }
                // Grapheme by grapheme, so only the changed ones are typed over; it must add up to the whole convert.
                var changes: [TextChange] = []
                var rebuilt = ""
                var offset = sel.location
                for ch in text {
                    let original = String(ch)
                    let out = converter.convert(original).text
                    rebuilt += out
                    let n = original.utf16.count
                    if !out.isEmpty, !out.unicodeScalars.elementsEqual(original.unicodeScalars) {
                        changes.append(TextChange(offset: offset, length: n, text: out))
                    }
                    offset += n
                }
                guard rebuilt.unicodeScalars.elementsEqual(whole.text.unicodeScalars) else { return .unavailable }
                target = whole.target
                return changes.isEmpty ? .nothing : .changes(changes)
            case .box:
                let window = FieldWindow(text: read.text, location: 0, caret: read.selection.location,
                                         reachesFieldStart: true, reachesFieldEnd: true)
                let result = BoxConversion.plan(window, classify: layouts.runClass) { side, grapheme in
                    layouts.converter(from: layouts.source(of: side))?.convert(grapheme).text ?? grapheme
                }
                switch result {
                case .nothing: return .nothing
                case .tooLong: return .tooLong
                case .convert(let p):
                    target = layouts.source(of: p.side.other)
                    return .changes(p.changes)
                }
            }
        }
        let gen = r.gen
        let result = await ax.run(job.source, expected: job.element, plan: plan, mayWrite: { self.claim(gen) })
        switch result {
        case .converted:
            // The caret moved by the length changes, not where the buffer ended: forget the buffer (X5 table).
            finish.bufferAfter = []
            guard let target else {   // can't happen: written after `plan` answered
                beep()
                return .noop(.replacement(.halted(after: .axSelectAndType)))
            }
            var switched = false
            if r.switchAfterConvert, !Task.isCancelled {
                // A selection keeps the P2-21 behaviour; a box convert's finish states the buffer itself.
                switched = await switchLanguage(target, job.source == .box)
            }
            return .converted(to: target, by: .axSelectAndType, switched: switched)
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case .tooLong:
            beep()
            return .noop(.runTooLong)
        case .abandoned:
            return .noop(.replacement(.abandoned))
        case .unavailable(.focusChanged):
            // Not the field the double-Shift was for: no other path either (it would read the new field).
            if !r.snapshot.hasRun { return await toggle(r, because: .fieldUnreadable) }
            beep()
            return .noop(.replacement(.exhausted))
        case .unavailable:
            return await fallBackFromChromium(r, layouts: layouts, finish: &finish)
        case .partial, .failed:
            finish.bufferAfter = []
            beep()
            return .noop(.replacement(.halted(after: .axSelectAndType)))
        }
    }

    /// P3-42: nothing was typed: the clipboard (when allowed) or the remembered buffer, exactly as without this path.
    private func fallBackFromChromium(_ r: ConvertRequest, layouts: LayoutSnapshot,
                                      finish: inout Finish) async -> ConvertOutcome {
        let decision = decide(r, layouts: layouts, allowClipboard: r.useClipboard, allowChromiumAX: false)
        return await apply(decision, r, layouts: layouts, finish: &finish)
    }

    /// P3-37 (b): the kept terminal buffer started in the element that has focus now.
    /// P3-41 (cmux): when AX can't name the element (no element at the buffer's first key, or none now), the identity
    /// check can't run. The buffer is then trusted only if no click happened since its first key, i.e. it crossed only
    /// an app switch away and back to the same terminal process (the processor already matched the pid). Before P3-41
    /// an unknown identity always forgot the buffer, so in such a terminal every buffer kept across an app switch was
    /// lost. Two known elements that differ: another window / tab / split, forgotten as before.
    private func terminalBufferStillFocused(_ snap: WordSnapshot) -> Bool {
        let now = currentReplacer().currentFocusedElement(timeout: ReplacementExecutor.axTimeout)
        if let anchor = terminalAnchor, anchor.epoch == snap.epoch, let then = anchor.element, let now {
            return now.isSameElement(as: then)
        }
        // P3-41: identity unknown at either end (or no anchor for this buffer: its note may not have run yet).
        return !snap.clickedSinceStart
    }

    /// P3-37 (b): a terminal buffer started (from the tap, through main): note the focused element. Identity only.
    func anchorTerminalBuffer(epoch: UInt64) {
        // P3-41: kept with a nil element too, so the check above knows the buffer started where AX names nothing.
        terminalAnchor = (epoch, currentReplacer().currentFocusedElement(timeout: ReplacementExecutor.axTimeout))
    }

    /// P3-40 (b): the same text once spaces, line breaks and other invisible characters are left out (scalar by
    /// scalar, both canonically composed). Chromium's `AXSelectedText` can drop or change the breaks between paragraphs,
    /// so only the visible characters can tell that ⌘C copied the selection AX reported. Linear in the two lengths.
    nonisolated static func sameVisibleText(_ a: String, _ b: String) -> Bool {
        func visible(_ s: String) -> [Unicode.Scalar] {
            s.precomposedStringWithCanonicalMapping.unicodeScalars.filter { u in
                if CharacterSet.whitespacesAndNewlines.contains(u) { return false }
                switch u.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator: return false
                default: return true
                }
            }
        }
        let x = visible(a)
        return !x.isEmpty && x == visible(b)
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

    private static func isAXWrite(_ step: ReplacementStep) -> Bool {
        if case .axWriteSelection = step { return true }
        return false
    }

    private static func isRead(_ step: ReplacementStep) -> Bool {
        switch step {
        case .axReadRunBeforeCaret, .axReadField: return true
        default: return false
        }
    }
}
