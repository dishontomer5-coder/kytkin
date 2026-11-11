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
//      every letter of the caret-side language anywhere in it into the other language (or the `LastRun` record
//      restores the previous convert, X6/X11), one AX write of the range from the first to the last changed
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
//     so a second double-Shift converts the same strokes straight back.
//   - an AX write that differs from the buffer (the whole box, an undo), a selection, or a halted chain →
//     `bufferAfter: []` (forget it all).
//   - nothing written → `nil, nil`.
//   Never a non-empty `bufferAfter` with `bufferRenderedIn` (asserted here and in the processor).
//
// Undo (X6, P3-35 X11): after an AX convert the controller keeps one `LastRun` record: ids, the written range, a
// SHA-256 fingerprint of the written text, and the text it replaced. A per-character convert doesn't round-trip
// exactly (`Akuo` → `שלום` → `akuo`; correct Hebrew next to the converted letters would flip too), so an exact undo
// needs the original. The next double-Shift uses it only while the snapshot says nothing touched the field since
// that convert (`untouchedSinceConvert == record.gen`) AND it re-verifies: same bundle ID, pid and focused element
// (`CFEqual`), and the field still holds exactly what was written at the recorded range (fingerprint). It then
// writes the original back and puts the caret where it was before the convert. Otherwise the record is dropped and
// the normal convert runs. Every request takes the record out first, so a record serves at most the very next
// double-Shift. P3-35 QA (owner): no age limit; `forgetUndoRecord` drops it (and its text) on the first key or click
// after the convert, a focus/app change, Pause or Secure Input.
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
//       finish. A known selection that can't be typed over (a line break) is pasted over. Empty box / no copy →
//       the remembered buffer by keys, else just switch. Undo: double-Shift again right away pastes the original back
//       (`ClipUndo`, held until the next key, click or focus change, like P3-35's).
//
// Privacy: text read through AX lives only inside `decide` (the replacer is ended before it returns). P3-35: the
// `LastRun` record holds the replaced text in memory, for the undo only (until the next key, click or focus change,
// then dropped; never stored or logged); the outcome holds steps only. Nothing here logs.

import CryptoKit
import Foundation

@TextActor final class ConvertController {
    /// Main-actor input-source switch. `keepsBuffer` = the change notification must not reset the tap's buffer:
    /// the finish that follows states the buffer itself (kept re-rendered in `target`, or forgotten).
    /// Returns true when `target` is (now) selected.
    typealias SwitchLanguage = @Sendable (_ target: InputSourceID, _ keepsBuffer: Bool) async -> Bool

    // P3-35 QA (owner, 2026-11-11): no age limit on the undo record any more (was 5 s, `lastRunMaxAgeNanos`). Owner:
    // "5 seconds is limiting. number one priority is functionality and user experience." It stays usable until the
    // user types a key or clicks (`untouchedSinceConvert`), focus, the field or the app changes, Kytkin pauses or
    // Secure Input starts (`forgetUndoRecord`, from AppController), or the field no longer holds exactly what was
    // written (fingerprint). The 5 s guarded against changes the tap can't see (dictation, autocorrect, a sync) being
    // taken for our text; since P3-35 the fingerprint already refuses any such change inside the written range.

    /// P2-59c (X6): the last AX convert. P3-35 (X11): ids, ranges, a fingerprint, and the replaced text (`original`,
    /// the only text field; checked by a Mirror test), held for the undo window only.
    struct LastRun {
        /// The convert's generation; usable only while the snapshot's `untouchedSinceConvert` equals it.
        let gen: UInt64
        let bundleID: String
        let processID: Int32
        /// The focused element written to (identity only, compared with `CFEqual`).
        let element: any FocusedElementIdentity
        /// Absolute UTF-16 offset and length of the text written (the range as it is now).
        let location: Int
        let length: Int
        /// P3-35: SHA-256 of the written text (`fingerprint(of:)`), to recognise it in the field without keeping it.
        let fingerprint: [UInt8]
        /// P3-35: the text the convert replaced, written back by an undo. In memory only, until the next key,
        /// click or focus change (P3-35 QA, owner); never stored or logged.
        let original: String
        /// P3-35: the caret before the convert (absolute UTF-16), where an undo puts it back.
        let originalCaret: Int
        /// The side the written text is on now (the convert's target), and the side it came from.
        let from: PairSide
        let to: PairSide
    }

    /// P3-37 (c): the last clipboard convert of a whole box, for the undo (double-Shift again right away). Ids, a
    /// fingerprint of what was pasted, and the box it replaced (`original`, the only text; in memory until the next key,
    /// click or focus change; never stored or logged).
    struct ClipUndo {
        let gen: UInt64
        let bundleID: String
        let processID: Int32
        let fingerprint: [UInt8]
        let original: String
        /// The side the pasted text is on (the convert's target), and the side the original is on.
        let from: PairSide
        let to: PairSide
    }

    /// P3-37 (c): one clipboard convert, decided synchronously in `decide` and run (with its bounded waits) in `run`.
    private struct ClipJob {
        let source: ClipboardConvert.Source
        /// The focused element at the start: every shortcut goes only while it still has focus.
        let element: any FocusedElementIdentity
        /// The remembered buffer's side (the box's direction), nil = the box's last letter.
        let direction: PairSide?
        let undo: ClipUndo?
    }

    private let keyWatcher: any KeyWatching
    private let clock: any Clock
    private let beep: @Sendable () -> Void
    private let makeReplacer: @TextActor @Sendable () -> any TextReplacing
    private let switchLanguage: SwitchLanguage
    /// P3-37 (c): the clipboard convert's seams (live: NSPasteboard + CGEvent); nil = never use the clipboard.
    private let makeClipboard: (@TextActor @Sendable () -> ClipboardConvert?)?

    private var replacer: (any TextReplacing)?
    private var clipboard: ClipboardConvert?
    /// P3-37 (c): the undo record of the last clipboard convert, for the next double-Shift only.
    private(set) var lastClip: ClipUndo?
    /// P3-37 (c): the user's clipboard, to put back after this request's finish (bounded).
    private var pendingRestore: ClipboardConvert.PendingRestore?
    /// P3-37 (b): the focused element a terminal's buffer started in.
    private var terminalAnchor: (epoch: UInt64, element: any FocusedElementIdentity)?
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
    /// P2-59c (X6): the undo record of the last AX run convert, for the next double-Shift only.
    private(set) var lastRun: LastRun?

    nonisolated init(keyWatcher: any KeyWatching, clock: any Clock = SystemClock(),
                     capabilities: ReplacementCapabilities = ReplacementCapabilities(),
                     beep: @escaping @Sendable () -> Void,
                     makeReplacer: @escaping @TextActor @Sendable () -> any TextReplacing,
                     switchLanguage: @escaping SwitchLanguage,
                     makeClipboard: (@TextActor @Sendable () -> ClipboardConvert?)? = nil) {
        self.keyWatcher = keyWatcher
        self.clock = clock
        self.capabilities = capabilities
        self.beep = beep
        self.makeReplacer = makeReplacer
        self.switchLanguage = switchLanguage
        self.makeClipboard = makeClipboard
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
        /// `isRun`: a run convert (not a selection). `record`: the X6 undo record of an AX run write.
        case replaced(target: InputSourceID, step: ReplacementStep, keptBuffer: Bool, isRun: Bool, record: LastRun?)
        case nothingToConvert
        /// P2-54(a): focus unknown and nothing remembered.
        case fieldUnreadable
        case failed(ConvertOutcome.NoopReason, beeps: Bool, textMayHaveChanged: Bool)
        /// P3-37 (c): run the clipboard convert (it waits, so it runs in `run`, not in `decide`).
        case clipboard(ClipJob)
    }

    private func run(_ request: ConvertRequest, layouts: LayoutSnapshot?, finish: inout Finish) async throws
        -> ConvertOutcome {
        try Task.checkCancellation()
        claimedGen = nil
        // X6: a record serves only the very next double-Shift; this one takes it out whatever it does.
        let record = lastRun
        lastRun = nil
        let clip = lastClip   // P3-37 (c): the same for the clipboard undo
        lastClip = nil
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
        let decision = decide(r, layouts: layouts, record: record, clip: clip, allowClipboard: r.useClipboard)
        return await apply(decision, r, layouts: layouts, finish: &finish)
    }

    private func apply(_ decision: Decision, _ r: ConvertRequest, layouts: LayoutSnapshot,
                       finish: inout Finish) async -> ConvertOutcome {
        switch decision {
        case .clipboard(let job):
            return await runClipboard(job, r, layouts: layouts, finish: &finish)
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
    private func decide(_ r: ConvertRequest, layouts: LayoutSnapshot, record: LastRun?, clip: ClipUndo?,
                        allowClipboard: Bool) -> Decision {
        let replacer = currentReplacer()
        defer { replacer.endReplacement() }
        let focus = replacer.focusInfo(timeout: ReplacementExecutor.axTimeout)
        // The chain ends the replacement (dropping the element) when it returns: keep the identity for P3-37's job.
        let element = replacer.focusedElement

        // P3-37 (a): a terminal's selection is display only (P2-36: never typed over). It used to beep and not even
        // switch; now it is ignored: the remembered line converts by keys, or double-Shift just switches.
        let terminalSelection = capabilities.method(for: r.bundleID) == .terminal
        if let selection = focus?.selection, !selection.isEmpty, !terminalSelection {
            let request = ReplacementRequest(kind: .convertSelection, bundleID: r.bundleID, snapshot: r.snapshot,
                                             selectionLength: selection.count)
            var target: InputSourceID?
            let outcome = runChain(request, focus: focus, old: selection, gen: r.gen, replacer: replacer,
                                   locateField: nil) { text in
                guard let c = layouts.convertGuessing(text) else { return nil }
                target = c.target
                return c.text
            }
            // P3-37 (c): a known selection Kytkin can't type over (a line break in it, in an unreadable app): paste it.
            if case .refused(let why) = outcome.result, why == .unsafeSelection || why == .noMethod, allowClipboard,
               let job = clipJob(r, layouts: layouts, focus: focus, element: element, source: .selection(selection),
                                 direction: nil, undo: nil) {
                return .clipboard(job)
            }
            guard case .replaced(let step) = outcome.result else { return Self.failure(outcome) }
            guard let target else {   // can't happen: a write only runs after `convert` answered
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            return .replaced(target: target, step: step, keptBuffer: false, isRun: false, record: nil)
        }
        return decideRun(r, layouts: layouts, focus: focus, element: element, record: record, clip: clip,
                         allowClipboard: allowClipboard, replacer: replacer)
    }

    /// P2-59 (001 §12.3 X4–X6): no selection, the run before the caret.
    private func decideRun(_ r: ConvertRequest, layouts: LayoutSnapshot, focus: FocusInfo?,
                           element: (any FocusedElementIdentity)?, record: LastRun?, clip: ClipUndo?,
                           allowClipboard: Bool, replacer: any TextReplacing) -> Decision {
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

        // P3-37 (c): an app whose box AX can't read: the clipboard first (the whole box, every line), the remembered
        // buffer only if that finds nothing. Direction: the buffer's language when it holds a letter of it.
        if allowClipboard, let f = focus,
           !ReplacementPlanner.readsField(bundleID: r.bundleID, caps: capabilities, focus: f) {
            let source = snap.renderedIn ?? r.currentSource
            let direction = layouts.side(of: source).flatMap { side in
                old?.contains { $0.isLetter && layouts.runClass(of: $0) == .strong(side) } == true ? side : nil
            }
            let undo = clip.flatMap { rec -> ClipUndo? in
                guard snap.untouchedSinceConvert == rec.gen, rec.bundleID == r.bundleID,
                      element?.processID == rec.processID else { return nil }
                return rec
            }
            if let job = clipJob(r, layouts: layouts, focus: focus, element: element, source: .box,
                                 direction: direction, undo: undo) {
                return .clipboard(job)
            }
        }

        // X6: the record is a candidate only while nothing touched the field since that convert, in the same app,
        // process and element, and while it is fresh. The text check follows in `locate`.
        let usable = record.flatMap { rec -> LastRun? in
            // P3-35 QA (owner): no age check any more (see `LastRun`).
            guard snap.untouchedSinceConvert == rec.gen, rec.bundleID == r.bundleID,
                  let element, element.processID == rec.processID, element.isSameElement(as: rec.element)
            else { return nil }
            return rec
        }

        // Captured from the chain's callbacks; local to this call (the text never leaves it).
        var box: BoxConversion.Result?
        var plan: BoxConversion.Plan?
        var undo: LastRun?
        var located: (location: Int, caret: Int)?
        /// P3-35: the buffer's strokes may stand for the range only when it ends at the caret (keys: no read at all).
        var bufferMayApply = true
        var target: InputSourceID?
        var fromBuffer = false
        var replaced: String?
        var written: String?

        // P3-35 (X11): the whole text box, or the record's range (undo).
        let locate: (FieldWindow) -> FieldEdit? = { window in
            if let rec = usable, let edit = Self.recordedUndo(rec, in: window) {
                undo = rec
                bufferMayApply = window.location + edit.offset + edit.length == window.caret
                located = (window.location + edit.offset, window.caret)
                return edit
            }
            // No record, or it no longer matches the field: drop it and convert normally.
            let result = BoxConversion.plan(window, classify: layouts.runClass) { side, grapheme in
                layouts.converter(from: layouts.source(of: side))?.convert(grapheme).text ?? grapheme
            }
            box = result
            guard case .convert(let p) = result else { return nil }
            plan = p
            located = (window.location + p.edit.offset, window.caret)
            bufferMayApply = window.location + p.edit.offset + p.edit.length == window.caret
            return p.edit
        }
        let convert: (String) -> String? = { text in
            if let rec = undo {
                guard rec.original != text else { return nil }
                // A kept, re-rendered buffer (switch off, X5) whose strokes give back exactly the original: the undo
                // keeps the buffer too, so the ping-pong goes on by strokes.
                fromBuffer = bufferMayApply && old.map { text.unicodeScalars.elementsEqual($0.unicodeScalars) } == true
                    && rendered.map { $0.text.unicodeScalars.elementsEqual(rec.original.unicodeScalars) } == true
                target = layouts.source(of: rec.to)
                replaced = text
                written = rec.original
                return rec.original
            }
            // P2-60: scalar equality, not String's canonical equivalence: a precomposed vs decomposed run must not
            // count as "exactly the buffer" (the key path backspaces by the buffer's own count).
            if bufferMayApply, let old, let rendered, text.unicodeScalars.elementsEqual(old.unicodeScalars) {
                // The buffer's text (keys, or an AX range that is exactly the buffer): convert by its strokes.
                guard rendered.text != old else { return nil }
                fromBuffer = true
                target = rendered.target
                replaced = text
                written = rendered.text
                return rendered.text
            }
            // The whole box: the plan's text for the range it named.
            guard let p = plan else { return nil }
            fromBuffer = false
            target = layouts.source(of: p.side.other)
            replaced = text
            written = p.text
            return p.text
        }

        let outcome = runChain(request, focus: focus, old: old, gen: r.gen, replacer: replacer, locateField: locate,
                               convert: convert)
        switch outcome.result {
        case .replaced(let step):
            guard let target, let toSide = layouts.side(of: target) else {   // can't happen (see `convert`)
                return .failed(.replacement(outcome.result), beeps: true, textMayHaveChanged: true)
            }
            var newRecord: LastRun?
            // P3-35: an undo keeps no record: a third double-Shift converts the restored box again, which is the
            // same convert as the first one (same caret, same letters).
            if case .axWriteSelection = step, undo == nil, let located, let element, let pid = element.processID,
               let written, !written.isEmpty, let replaced {
                newRecord = LastRun(gen: r.gen, bundleID: r.bundleID, processID: pid, element: element,
                                    location: located.location, length: written.utf16.count,
                                    fingerprint: Self.fingerprint(of: written), original: replaced,
                                    originalCaret: located.caret, from: toSide, to: toSide.other)
            }
            return .replaced(target: target, step: step, keptBuffer: fromBuffer, isRun: true, record: newRecord)
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
                         direction: PairSide?, undo: ClipUndo?) -> ClipJob? {
        guard makeClipboard != nil, !r.inAddressBar, let f = focus, let element, !f.isSecure,
              f.role != FocusInfo.secureTextFieldRole, !f.hasMarkedText, layouts.clipboardShortcutsAreSafe
        else { return nil }
        // Never in a terminal (bracketed paste, the prompt), a remote desktop or VM, or an app the user set to "Off"
        // or to "Keys only" (their choice means keys and nothing else).
        switch capabilities.method(for: r.bundleID) {
        case .keysOnly: break   // Chromium / Electron: AX may be off, so the role says nothing; the seed vouches for it
        case .auto, .preferPaste:
            // Any other app: only a real text box. ⌘A in a list, table or file browser selects items, and ⌘V could
            // paste over all of them (Numbers, Finder).
            guard let role = f.role, Self.clipboardTextRoles.contains(role) else { return nil }
        case .terminal, .noUnicode, .disabled: return nil
        }
        if capabilities.override(for: r.bundleID) == .keysOnly { return nil }
        // Editors: ⌘A is the whole file and the window may hold a terminal (a pasted line break could run a command).
        if ReplacementCapabilities.isEditor(r.bundleID) { return nil }
        return ClipJob(source: source, element: element, direction: direction, undo: undo)
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
        var undone: ClipUndo?
        let convert: (String) -> ClipboardConvert.Conversion = { text in
            if case .box = job.source, let rec = job.undo, Self.clipFingerprint(of: text) == rec.fingerprint {
                undone = rec
                target = layouts.source(of: rec.to)
                return .replace(rec.original)
            }
            switch job.source {
            case .selection:
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
        case let .pasted(original, written):
            guard let target, let toSide = layouts.side(of: target) else {   // can't happen: pasted after `convert`
                finish.bufferAfter = []
                beep()
                return .noop(.replacement(.halted(after: .pasteboard)))
            }
            // The caret is at the end of the box now, not where the buffer ended: forget the buffer (X5 table).
            finish.bufferAfter = []
            if undone == nil, case .box = job.source, let pid = element.processID {
                lastClip = ClipUndo(gen: r.gen, bundleID: r.bundleID, processID: pid,
                                    fingerprint: Self.clipFingerprint(of: written), original: original,
                                    from: toSide, to: toSide.other)
            }
            var switched = false
            if r.switchAfterConvert, !Task.isCancelled {
                // keepsBuffer: the finish forgets the buffer itself, so the undo's `untouchedSinceConvert` survives.
                switched = await switchLanguage(target, true)
            }
            return .converted(to: target, by: .pasteboard, switched: switched)
        case .nothingToConvert:
            return await toggle(r, because: .nothingToConvert)
        case .tooLong:
            beep()
            return .noop(.runTooLong)
        case .boxEmpty, .unavailable:
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
        let decision = decide(r, layouts: layouts, record: nil, clip: nil, allowClipboard: false)
        return await apply(decision, r, layouts: layouts, finish: &finish)
    }

    /// P3-37 (b): the kept terminal buffer started in the element that has focus now. Unknown either way = no.
    private func terminalBufferStillFocused(_ snap: WordSnapshot) -> Bool {
        guard let anchor = terminalAnchor, anchor.epoch == snap.epoch,
              let now = currentReplacer().currentFocusedElement(timeout: ReplacementExecutor.axTimeout) else {
            return false
        }
        return now.isSameElement(as: anchor.element)
    }

    /// P3-37 (b): a terminal buffer started (from the tap, through main): note the focused element. Identity only.
    func anchorTerminalBuffer(epoch: UInt64) {
        terminalAnchor = currentReplacer().currentFocusedElement(timeout: ReplacementExecutor.axTimeout)
            .map { (epoch, $0) }
    }

    /// P3-37 (c): the undo's fingerprint of a whole box as ⌘C copies it: P3-35's, ignoring trailing line breaks (some
    /// apps copy a box with one more or one less at the end).
    nonisolated static func clipFingerprint(of text: String) -> [UInt8] {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, ReplacementPlanner.isLineBreak(last) { scalars.removeLast() }
        var trimmed = ""
        trimmed.unicodeScalars.append(contentsOf: scalars)
        return fingerprint(of: trimmed)
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

    /// P3-35 (X6, X11): the record's range, if the window still holds exactly what was written there (fingerprint),
    /// starting and ending on character boundaries. The undo writes `original` back and restores the caret. nil = the
    /// record no longer matches (the normal convert runs).
    static func recordedUndo(_ rec: LastRun, in window: FieldWindow) -> FieldEdit? {
        let units = Array(window.text.utf16)
        let offset = rec.location - window.location
        guard rec.length > 0, offset >= 0, offset + rec.length <= units.count else { return nil }
        let slice = units[offset..<(offset + rec.length)]
        let text = String(decoding: slice, as: UTF16.self)
        guard Array(text.utf16) == Array(slice), fingerprint(of: text) == rec.fingerprint else { return nil }
        return FieldEdit(offset: offset, length: rec.length, caretAfter: rec.originalCaret)
    }

    /// P3-35: SHA-256 of `text` as the field may read it back (canonical composition, a no-break space as a space,
    /// every line-break unit as LF: what `ReplacementExecutor.readsBackAs` accepts), so the undo recognises our own
    /// write without keeping a copy of it.
    nonisolated static func fingerprint(of text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for u in text.precomposedStringWithCanonicalMapping.utf16 {
            let v: UInt16 = switch u {
            case 0xA0: 0x20
            case 0x0D, 0x2028, 0x2029: 0x0A
            default: u
            }
            bytes.append(UInt8(v & 0xFF))
            bytes.append(UInt8(v >> 8))
        }
        return Array(SHA256.hash(data: bytes))
    }

    /// P3-35 QA (owner): drops the undo record and the replaced text it holds. AppController calls it (through
    /// `ConvertDispatcher.forgetUndo`, after any convert still queued) on the first key or click after a convert, a
    /// focus, window or app change, Pause and Secure Input. Replaces the P3-35 5 s expiry task.
    func forgetUndoRecord() {
        lastRun = nil
        lastClip = nil   // P3-37 (c)
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
