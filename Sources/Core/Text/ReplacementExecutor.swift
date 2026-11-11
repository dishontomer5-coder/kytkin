// P2-18: Executes ReplacementSteps (001 §2.2/§3c, R5) over two seams: AX (`FocusedElementProviding`) and key
// posting (`KeyEventPosting`). All of TextReplacer's decisions live here, in Core, so they're unit-tested with
// fakes; `System/Text/TextReplacer` only plugs in the live AX and CGEvent adapters.
//
// Safety rules enforced here, again, even though the planner already applies them (defence in depth):
//  - nothing runs unless `focusInfo` just read a focused element that is not secure and not composing;
//  - every AX write is read back; a failure falls through only if the original text is still in place;
//  - nothing typed may hold a line break, tab or other control character (design.md invariant);
//  - every posted event carries the `ours` marker and no modifier flags (`SyntheticKeyEvent`);
//  - P2-49: before any key step, the focused element must still be the one `focusInfo` read (keys go to whatever
//    has focus); before a type-over, the selection must still be a selection of `old`'s length (else the text
//    would be inserted next to it, twice); after the first AX timeout nothing more is asked of the app.
// Text read through AX stays in memory for one replacement and is never logged (no logging in Text/, B12).

import Foundation

@TextActor final class ReplacementExecutor: TextReplacing {
    /// 001 §7 B5: messaging timeout on every element.
    static let axTimeout: Double = 0.25

    private let focusProvider: any FocusedElementProviding
    private let poster: any KeyEventPosting

    // One replacement's state, cleared by `focusInfo` and `endReplacement`.
    /// The focused element, behind the P2-49 timeout latch.
    private var element: TimeoutLatchedElement?
    /// P2-49 item 5: tripped by the first AX timeout of this replacement; reset by `focusInfo`/`endReplacement`.
    private let latch = AXTimeoutLatch()
    /// The messaging timeout `focusInfo` was given, reused for the P2-49 focus re-check.
    private var timeout = ReplacementExecutor.axTimeout
    /// True only after `focusInfo` read a focused element that is neither secure nor composing.
    private var focusIsSafe = false
    /// The range `readRunBeforeCaret` found; the next AX write targets it.
    private var pendingRange: TextRange?
    /// P3-35: where a successful write of `pendingRange` leaves the caret (nil = after the new text), and where a
    /// write that changed nothing puts it back (the user's caret; nil = `pendingRange.end`, the P2-59 run).
    private var pendingCaretAfter: Int?
    private var pendingRestoreCaret: Int?
    private(set) var wordBeforeCaret: String?
    /// P3-35: the last read's range ends at the caret (a key fallback could delete exactly it).
    private(set) var readRangeEndsAtCaret = true

    /// P2-59c: the element `focusInfo` read as safe, for same-element checks (identity only).
    var focusedElement: (any FocusedElementIdentity)? { focusIsSafe ? element?.inner : nil }

    init(focusProvider: any FocusedElementProviding, poster: any KeyEventPosting) {
        self.focusProvider = focusProvider
        self.poster = poster
    }

    func endReplacement() {
        element = nil
        focusIsSafe = false
        pendingRange = nil
        pendingCaretAfter = nil
        pendingRestoreCaret = nil
        wordBeforeCaret = nil
        readRangeEndsAtCaret = true
        latch.reset()
    }

    // MARK: - Focus

    /// P3-37: the focused element right now, identity only (no attribute read, no replacement state touched).
    func currentFocusedElement(timeout: Double) -> (any FocusedElementIdentity)? {
        guard case .success(let el) = focusProvider.focusedTextElement(timeout: timeout) else { return nil }
        return el
    }

    /// P3-41 QA: the focused application's pid, nil = unknown (identity only).
    func focusedApplicationPID(timeout: Double) -> Int32? {
        focusProvider.focusedApplicationPID(timeout: timeout)
    }

    /// A read that gives up on the whole focus read (timeout, no permission, element gone).
    private struct Abort: Error {}

    /// The value, nil if the attribute is absent or unreadable, or throws `Abort` (see `abortsFocusRead`).
    private func optional<T>(_ r: Result<T, AXAccessError>) throws -> T? {
        switch r {
        case .success(let v): return v
        case .failure(let e): if e.abortsFocusRead { throw Abort() }; return nil
        }
    }

    func focusInfo(timeout: Double) -> FocusInfo? {
        endReplacement()
        self.timeout = timeout
        guard case .success(let focused) = focusProvider.focusedTextElement(timeout: timeout) else { return nil }
        let el = TimeoutLatchedElement(focused, latch: latch)
        do {
            // A focused element without a role is something AX can't describe: refuse (001 §12 T4).
            guard let role = try optional(el.string(.role)) else { return nil }
            // P2-49 item 6: absent (no value / unsupported) is fine; a read that failed or returned another type
            // can't rule out a password field, so it counts as secure. A timeout aborts the read (nil) as before.
            let subroleUnreadable: Bool
            let subrole: String?
            switch el.string(.subrole) {
            case .success(let s): subrole = s; subroleUnreadable = false
            case .failure(let e):
                if e.abortsFocusRead { throw Abort() }
                subrole = nil
                subroleUnreadable = e == .failed
            }
            // Secure first, and read nothing else from a password field.
            let securelyNamed = role == FocusInfo.secureTextFieldRole || subrole == FocusInfo.secureTextFieldRole
            if securelyNamed || subroleUnreadable {
                // P3-41 QA: say whether only the failed read made it "secure" (a real subrole must never get keys).
                return FocusInfo(role: role, isSecure: true, hasMarkedText: false, selTextSettable: false,
                                 selRangeSettable: false, selection: nil, fromFailedRead: !securelyNamed)
            }
            switch try composing(el) {
            case .no: break
            case let c:
                // P3-41 QA: a real marked range (an IME composing) is never typed over, even by a terminal fallback.
                return FocusInfo(role: role, isSecure: false, hasMarkedText: true, selTextSettable: false,
                                 selRangeSettable: false, selection: nil, fromFailedRead: c == .unknown)
            }
            let selection = try optional(el.string(.selectedText))
            let range = try currentSelectedRange(el)
            let textSettable = try optional(el.isSettable(.selectedText)) ?? false
            let rangeSettable = (try optional(el.isSettable(.selectedTextRange)) ?? false) && range != nil
            var readsCaret = false
            // P3-35: a caret at the field start counts too (the whole box converts, from the nearest letter after).
            if let range, range.isCaret, range.location >= 0 {
                readsCaret = try optional(el.supportsStringForRange()) ?? false
            }
            element = el
            focusIsSafe = true
            return FocusInfo(role: role, isSecure: false, hasMarkedText: false, selTextSettable: textSettable,
                             selRangeSettable: rangeSettable, selection: selection, canReadBeforeCaret: readsCaret)
        } catch {
            return nil
        }
    }

    /// R5: Cocoa's marked range, or WebKit's marked text. A read that fails (not just "absent") counts as
    /// composing: an IME composition can't be ruled out.
    /// P3-41 QA: `.yes` = AX reports marked text; `.unknown` = only a failed read says so (still composing for every
    /// caller except a terminal's fallback, `FocusInfo.fromFailedRead`).
    private enum Composing { case no, yes, unknown }

    private func composing(_ el: any AXTextElement) throws -> Composing {
        switch el.range(.markedTextRange) {
        case .success(let r): if r.length > 0 { return .yes }
        case .failure(let e):
            if e.abortsFocusRead { throw Abort() }
            if e == .failed { return .unknown }
        }
        switch el.string(.webKitMarkedText) {
        case .success(let s): return s.isEmpty ? .no : .yes
        case .failure(let e):
            if e.abortsFocusRead { throw Abort() }
            return e == .failed ? .unknown : .no
        }
    }

    /// The selected range, or nil if absent or implausible (R5: WebKit reported `(5, 4294967292)`).
    private func currentSelectedRange(_ el: any AXTextElement) throws -> TextRange? {
        guard let r = try optional(el.range(.selectedTextRange)), r.location >= 0, r.length >= 0 else { return nil }
        if let n = try optional(el.integer(.numberOfCharacters)), r.end > n { return nil }
        return r
    }

    // MARK: - Steps

    func perform(_ step: ReplacementStep, old: String, new: String) -> StepOutcome {
        guard focusIsSafe else { return .unavailable }
        switch step {
        case .axWriteSelection(let verify): return axWriteSelection(old: old, new: new, verify: verify)
        case .typeOverSelection: return typeOverSelection(old: old, new: new)
        case .backspaceAndType(let count): return backspaceAndType(count: count, old: old, new: new)
        // P2-59: the run read needs a locator, so it only runs through `readRunBeforeCaret`.
        case .axReadRunBeforeCaret, .axReadField: return .unavailable
        case .pasteboard, .keyCodesAfterSwitch: return .unavailable   // P3 / P4: not in the MVP
        case .axSelectAndType: return .unavailable   // P3-42: only `ChromiumAXConvert` runs it
        }
    }

    /// R5 §A: select the target range (stale path), check the selection is exactly `old`, set `AXSelectedText`,
    /// then read back.
    private func axWriteSelection(old: String, new: String, verify: Bool) -> StepOutcome {
        guard let el = element, !old.isEmpty, !new.isEmpty else { return .unavailable }
        guard let pending = pendingRange else { return axWrite(el, old: old, new: new, verify: verify, select: nil) }
        // P2-18 QA: the stale path selected the word itself. Whatever happens, never leave a selection behind:
        // the user's next key would replace it (the word, or the converted word) and their text would be lost.
        pendingRange = nil
        let caretAfter = pendingCaretAfter
        let restore = pendingRestoreCaret ?? pending.end
        pendingCaretAfter = nil
        pendingRestoreCaret = nil
        let outcome = axWrite(el, old: old, new: new, verify: verify, select: pending)
        if outcome.verdict == .done {
            if let caretAfter {
                // P3-35: the whole box was written; the caret goes back where the user had it (best effort: the
                // text is verified, so a caret the app won't move doesn't fail the convert).
                placeCaret(el, at: caretAfter)
            } else {
                collapseSelection(el, to: pending.location + new.utf16.count)
            }
        } else if outcome.fieldUntouched {
            // P2-59 (001 §12.3 X4): untouched only with the caret verified back where the user left it. If the run
            // were still selected, a key fallback's Backspace would delete it all and then N − 1 more before it.
            // P3-35: "where the user left it" is the caret the read saw, which a whole-box range may not end at.
            if !collapseSelection(el, to: restore) {
                return StepOutcome(verdict: outcome.verdict, fieldUntouched: false)
            }
        } else {
            collapseSelection(el, to: nil)           // unknown text: only drop the selection, at its end
        }
        return outcome
    }

    /// Range only (never text): if something is selected, put a caret at `location` (nil = the selection's end),
    /// then read the range back. True when the read-back shows a caret at `location` (at any place for nil).
    /// A caret the app already placed is left alone (and verified like any other).
    @discardableResult
    private func collapseSelection(_ el: any AXTextElement, to location: Int?) -> Bool {
        guard case .success(let current) = el.range(.selectedTextRange) else { return false }
        if !current.isCaret {
            let caret = TextRange(location: location ?? current.end, length: 0)
            guard case .success = el.setRange(caret, for: .selectedTextRange),
                  case .success(let after) = el.range(.selectedTextRange) else { return false }
            return after.isCaret && (location == nil || after.location == location)
        }
        return location == nil || current.location == location
    }

    /// P3-35: put a caret at `location` whatever is selected now, then read it back. True when it is there.
    @discardableResult
    private func placeCaret(_ el: any AXTextElement, at location: Int) -> Bool {
        let caret = TextRange(location: location, length: 0)
        if case .success(caret) = el.range(.selectedTextRange) { return true }
        guard case .success = el.setRange(caret, for: .selectedTextRange),
              case .success(let after) = el.range(.selectedTextRange) else { return false }
        return after == caret
    }

    private func axWrite(_ el: any AXTextElement, old: String, new: String, verify: Bool,
                         select pending: TextRange?) -> StepOutcome {
        guard case .success(true) = el.isSettable(.selectedText) else { return .unavailable }
        let target: TextRange
        if let pending {
            guard case .success = el.setRange(pending, for: .selectedTextRange) else { return .unavailable }
            target = pending
        } else {
            guard case .success(let r) = el.range(.selectedTextRange) else { return .unavailable }
            target = r
        }
        // Stale-range guard: the selection must be exactly the text we were asked to replace.
        guard target.length == old.utf16.count, case .success(old) = el.string(.selectedText) else {
            return .unavailable
        }
        // P3-40 (b): a user's selection (no pending range): the field's own text there must agree with AXSelectedText.
        if pending == nil, !fieldTextAgrees(el, old: old, at: target) { return .unavailable }
        guard case .success = el.setString(new, for: .selectedText) else {
            return StepOutcome(verdict: .unavailable, fieldUntouched: isIntact(el, old: old, at: target))
        }
        guard verify else { return .done }
        if readBack(el, new: new, at: target) { return .done }
        // R5: "success" that changed nothing (NSTextField not editing, WebKit). Fall through only if the
        // original is still selected; any other state is unknown, so the chain stops.
        return StepOutcome(verdict: .failedVerify, fieldUntouched: isIntact(el, old: old, at: target))
    }

    /// The text at `target` is now `new`, and the caret sits after it (or `new` is selected).
    private func readBack(_ el: any AXTextElement, new: String, at target: TextRange) -> Bool {
        let written = TextRange(location: target.location, length: new.utf16.count)
        let textThere: String?
        switch el.string(in: written) {
        case .success(let s): textThere = s
        case .failure:
            // No AXStringForRange: compare against the whole value, sliced in UTF-16 units.
            guard case .success(let value) = el.string(.value) else { return false }
            let units = Array(value.utf16)
            guard written.end <= units.count else { return false }
            textThere = String(decoding: units[written.location..<written.end], as: UTF16.self)
        }
        guard let textThere, Self.readsBackAs(textThere, new),
              case .success(let sel) = el.range(.selectedTextRange) else { return false }
        return sel == TextRange(location: written.end, length: 0) || sel == written
    }

    /// P3-33: the read-back shows `new`, allowing only what editors do to whitespace they own, unit for unit: a
    /// no-break space read back as a space or the reverse (WebKit's contenteditable rebalances spaces on insert, so
    /// Mail/Safari fields read back U+0020 for a written U+00A0), and one line-break unit for another (`\n` / `\r` /
    /// U+2028 / U+2029). Same UTF-16 length, every other unit identical. A strict compare there failed the write's
    /// verify, which marks AX broken for the app for the session (`ReplacementCapabilities.record`), and every later
    /// double-Shift then fell back to the word buffer: a likely cause of "only ~3 words change" in Mail.
    /// P3-33 QA: canonical equivalence (`==`) still counts, as before P3-33 (`textThere == new`): an app that stores
    /// combining marks in canonical order wrote our text. A strict scalar compare there would fail the verify and mark
    /// AX broken for the app for the session, the very fallback this tolerance exists to avoid. A failed write leaves
    /// the old run, whose letters differ, so neither rule can hide one.
    nonisolated static func readsBackAs(_ read: String, _ new: String) -> Bool {
        if read == new { return true }
        let r = Array(read.utf16), n = Array(new.utf16)
        guard r.count == n.count else { return false }
        func space(_ u: UInt16) -> Bool { u == 0x20 || u == 0xA0 }
        func lineBreak(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 }
        for (x, y) in zip(r, n) where x != y {
            if space(x) && space(y) { continue }
            if lineBreak(x) && lineBreak(y) { continue }
            return false
        }
        return true
    }

    /// The original text is still selected at the same place: nothing was written.
    private func isIntact(_ el: any AXTextElement, old: String, at target: TextRange) -> Bool {
        guard case .success(old) = el.string(.selectedText), case .success(target) = el.range(.selectedTextRange)
        else { return false }
        return true
    }

    /// R5 §B: typing replaces the selection. Never types over a selection holding a control character (§12 T2).
    private func typeOverSelection(old: String, new: String) -> StepOutcome {
        guard !old.isEmpty, !ReplacementPlanner.containsUnsafeCharacter(old),
              let events = KeyStrokeComposer.typing(new), focusIsUnchanged(), selectionStillSpans(old),
              selectedFieldTextAgrees(old)
        else { return .unavailable }
        return post(events)
    }

    /// P3-40 (b): Chromium/Electron's `AXSelectedText` can leave out the line breaks between paragraphs (Slack: a
    /// selection over two lines converted into one line). Where the field also answers `AXStringForRange` for the
    /// selected range, that text must read as `old` (the read-back tolerance: same length, spaces and line-break
    /// units interchangeable); a break AX's selected text dropped makes it longer, and the type-over or AX write is
    /// refused. A range or a read the app won't give can't be checked (true: the P2-49 checks above still hold).
    private func selectedFieldTextAgrees(_ old: String) -> Bool {
        guard let el = element else { return false }
        guard case .success(let r) = el.range(.selectedTextRange), r.location >= 0, r.length > 0 else { return true }
        return fieldTextAgrees(el, old: old, at: r)
    }

    private func fieldTextAgrees(_ el: any AXTextElement, old: String, at r: TextRange) -> Bool {
        switch el.string(in: r) {
        // P3-41 QA (P3-40 (b)): an empty answer for a non-empty range is a non-answer (some apps give "" for ranges they
        // don't support), not a disagreement: no false refusal in such an app.
        case .success(let s): return s.isEmpty || Self.readsBackAs(s, old)
        case .failure(let e): return !e.abortsFocusRead
        }
    }

    /// P2-49 item 2: re-read the selected range right before typing over it. If it became a caret (an earlier
    /// step or the app dropped it) or its length changed, typing would insert `new` beside the text instead of
    /// replacing it: the text would appear twice. Refuse then. A range AX won't give (absent, unsupported, wrong
    /// type) or reports implausibly (R5: WebKit's `(5, 4294967292)`) can't be checked, so the selected *text* must
    /// still be exactly `old` instead (QA P2-49: the planner only types over a selection `focusInfo` read as text,
    /// so that read works in these apps; a collapsed selection reads as ""). A timeout (latched, item 5) or a
    /// vanished element refuses.
    private func selectionStillSpans(_ old: String) -> Bool {
        guard let el = element else { return false }
        switch el.range(.selectedTextRange) {
        case .failure(let e): return !e.abortsFocusRead && selectedTextIs(old, el)
        case .success(let r):
            guard r.location >= 0, r.length >= 0 else { return selectedTextIs(old, el) }   // implausible
            switch el.integer(.numberOfCharacters) {
            case .success(let n) where r.end > n: return selectedTextIs(old, el)          // implausible
            case .failure(let e) where e.abortsFocusRead: return false
            default: break
            }
            return !r.isCaret && r.length == old.utf16.count
        }
    }

    /// The selected text reads back as exactly `old` (same scalars). Any failure = can't tell = no.
    private func selectedTextIs(_ old: String, _ el: any AXTextElement) -> Bool {
        guard case .success(let s) = el.string(.selectedText) else { return false }
        return s.unicodeScalars.elementsEqual(old.unicodeScalars)
    }

    /// P2-49 item 3: keys go to whatever has focus, so before a key step the focused element must still be the
    /// one `focusInfo` read (live: `CFEqual` through `FocusedElementIdentity`). Can't tell (no element, a timeout,
    /// the latch already tripped) = changed: refuse.
    private func focusIsUnchanged() -> Bool {
        guard let el = element, !latch.tripped else { return false }
        switch latch.guarded({ focusProvider.focusedTextElement(timeout: timeout) }) {
        case .success(let now): return now.isSameElement(as: el.inner)
        case .failure: return false
        }
    }

    /// R5 §B: Backspace × graphemes on screen, then type. `old`, when given, must render to exactly `count`
    /// graphemes, so a mismatch upstream never deletes the wrong amount.
    private func backspaceAndType(count: Int, old: String, new: String) -> StepOutcome {
        if !old.isEmpty && old.count != count { return .unavailable }
        guard let deletes = KeyStrokeComposer.backspaces(count),
              let typing = KeyStrokeComposer.typing(new), focusIsUnchanged() else { return .unavailable }
        return post(deletes + typing)
    }

    /// P3-41: see `TextReplacing.postTerminalKeys`. Composed and checked exactly like `backspaceAndType`'s events.
    func postTerminalKeys(count: Int, new: String) -> StepOutcome {
        guard count > 0, let deletes = KeyStrokeComposer.backspaces(count), let typing = KeyStrokeComposer.typing(new)
        else { return .unavailable }
        return post(deletes + typing)
    }

    /// P2-59 (001 §12.3 X4): one `AXStringForRange` read of `[max(0, caret − maxChars), caret)` (P3-33: smaller
    /// retries if that read fails or has the wrong length), then `locate`
    /// finds the run in it; its range is remembered for the AX write that follows. Writes nothing.
    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        pendingRange = nil
        wordBeforeCaret = nil
        guard focusIsSafe, let el = element, maxChars > 0, let caret = try? currentSelectedRange(el),
              caret.isCaret, caret.location > 0 else { return .unavailable }
        // The read must return exactly the window, or the offsets mean nothing. P3-33: a failed or wrong-length read
        // of a big window is retried once per smaller one (nearest the caret), so far text an app counts differently
        // costs only the far part of the run, not the whole AX path. A timeout ends it (P2-49 item 5).
        var sizes = [maxChars]
        for n in ReplacementPlanner.runReadRetryChars where n < maxChars && n < caret.location { sizes.append(n) }
        var found: (text: String, start: Int)?
        for size in sizes {
            let start = max(0, caret.location - size)
            let window = TextRange(location: start, length: caret.location - start)
            if case .success(let text) = el.string(in: window), text.utf16.count == window.length {
                found = (text, start)
                break
            }
            if latch.tripped { return .unavailable }
        }
        guard let found else { return .unavailable }
        let text = found.text, start = found.start
        let read = StepOutcome(verdict: .done, fieldUntouched: true)
        guard let run = locate(BeforeCaretWindow(text: text, location: start, reachesFieldStart: start == 0)) else {
            return read   // read fine, nothing there
        }
        // Defence in depth: the run ends at the caret, lies inside the window, starts and ends on scalar boundaries
        // (a split surrogate would decode to U+FFFD), and holds no control character other than a line break (§12 T2,
        // X3; P3-33: the run crosses line breaks, which the AX write puts back unchanged; they are never typed).
        let units = Array(text.utf16)
        guard run.offset >= 0, run.length > 0, run.offset + run.length == units.count else { return .unavailable }
        let slice = units[run.offset...]
        let runText = String(decoding: slice, as: UTF16.self)
        guard Array(runText.utf16) == Array(slice), !ReplacementPlanner.containsHardStop(runText) else {
            return .unavailable
        }
        pendingRange = TextRange(location: start + run.offset, length: run.length)
        wordBeforeCaret = runText
        return read
    }

    /// P3-35 (001 §12.3 X11): the whole-box read. The field's length (`AXNumberOfCharacters`) says what "whole" is;
    /// a field of ≤ `maxChars` units is read in one `AXStringForRange`. A bigger one, or a read that fails or comes
    /// back with the wrong length, is read as a window of that size around the caret (¾ before it, ¼ after), then of
    /// each `ReplacementPlanner.fieldReadRetryChars` size, until one reads exactly. A length AX won't give: the window
    /// ends at the caret (the P3-33 read). A timeout ends it (P2-49 item 5). `locate` names the range; it is
    /// remembered for the AX write that follows, with the caret to restore. Writes nothing.
    func readField(maxChars: Int, locate: (FieldWindow) -> FieldEdit?) -> StepOutcome {
        pendingRange = nil
        pendingCaretAfter = nil
        pendingRestoreCaret = nil
        wordBeforeCaret = nil
        readRangeEndsAtCaret = true
        guard focusIsSafe, let el = element, maxChars > 0, let caret = try? currentSelectedRange(el),
              caret.isCaret else { return .unavailable }
        var total: Int?
        switch el.integer(.numberOfCharacters) {
        case .success(let n) where n >= caret.location: total = n
        case .failure(let e) where e.abortsFocusRead: return .unavailable
        default: total = nil
        }
        if latch.tripped { return .unavailable }
        let read = StepOutcome(verdict: .done, fieldUntouched: true)
        if total == 0 { return read }   // an empty field: nothing there

        var sizes = [maxChars]
        for n in ReplacementPlanner.fieldReadRetryChars where n < maxChars && n < (total ?? caret.location) {
            sizes.append(n)
        }
        var found: (text: String, range: TextRange)?
        for size in sizes {
            let range = Self.window(size: size, caret: caret.location, total: total)
            guard range.length > 0 else { return read }
            if case .success(let text) = el.string(in: range), text.utf16.count == range.length {
                found = (text, range)
                break
            }
            if latch.tripped { return .unavailable }
        }
        guard let found else { return .unavailable }
        let window = FieldWindow(text: found.text, location: found.range.location, caret: caret.location,
                                 reachesFieldStart: found.range.location == 0,
                                 reachesFieldEnd: total.map { found.range.end == $0 } ?? false)
        guard let edit = locate(window) else { return read }   // read fine, nothing there
        // Defence in depth: the range lies inside the window, starts and ends on scalar boundaries (a split surrogate
        // would decode to U+FFFD) and holds no control character other than a line break or a tab (both are written
        // back unchanged by the AX write and never typed: a key fallback needs the range to be the word buffer).
        let units = Array(found.text.utf16)
        guard edit.offset >= 0, edit.length > 0, edit.offset + edit.length <= units.count else { return .unavailable }
        let slice = units[edit.offset..<(edit.offset + edit.length)]
        let text = String(decoding: slice, as: UTF16.self)
        guard Array(text.utf16) == Array(slice), !ReplacementPlanner.containsFieldStop(text) else {
            return .unavailable
        }
        if let after = edit.caretAfter, after < 0 { return .unavailable }
        let range = TextRange(location: found.range.location + edit.offset, length: edit.length)
        pendingRange = range
        pendingCaretAfter = edit.caretAfter
        pendingRestoreCaret = caret.location
        readRangeEndsAtCaret = range.end == caret.location
        wordBeforeCaret = text
        return read
    }

    /// P3-35: the range to read: the whole field when it fits `size`, else `size` units around the caret, ¾ before it
    /// (what was just typed is usually before the caret). An unknown length: `size` units ending at the caret.
    nonisolated static func window(size: Int, caret: Int, total: Int?) -> TextRange {
        guard let total else {
            let start = max(0, caret - size)
            return TextRange(location: start, length: caret - start)
        }
        if total <= size { return TextRange(location: 0, length: total) }
        let start = min(max(0, caret - size * 3 / 4), total - size)
        return TextRange(location: start, length: size)
    }

    /// Checks every event first, then posts in order. If the poster refuses the first event nothing went out;
    /// after that the field state is unknown and the chain must stop.
    private func post(_ events: [SyntheticKeyEvent]) -> StepOutcome {
        guard !events.isEmpty, events.allSatisfy(\.isSafeToPost) else { return .unavailable }
        for (i, e) in events.enumerated() {
            if !poster.post(e) { return StepOutcome(verdict: .unavailable, fieldUntouched: i == 0) }
        }
        return .done
    }
}
