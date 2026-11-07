// P2-18: Executes ReplacementSteps (001 §2.2/§3c, R5) over two seams: AX (`FocusedElementProviding`) and key
// posting (`KeyEventPosting`). All of TextReplacer's decisions live here, in Core, so they're unit-tested with
// fakes; `System/Text/TextReplacer` only plugs in the live AX and CGEvent adapters.
//
// Safety rules enforced here, again, even though the planner already applies them (defence in depth):
//  - nothing runs unless `focusInfo` just read a focused element that is not secure and not composing;
//  - every AX write is read back; a failure falls through only if the original text is still in place;
//  - nothing typed may hold a line break, tab or other control character (design.md invariant);
//  - every posted event carries the `ours` marker and no modifier flags (`SyntheticKeyEvent`).
// Text read through AX stays in memory for one replacement and is never logged (no logging in Text/, B12).

import Foundation

@TextActor final class ReplacementExecutor: TextReplacing {
    /// 001 §7 B5: messaging timeout on every element.
    static let axTimeout: Double = 0.25

    private let focusProvider: any FocusedElementProviding
    private let poster: any KeyEventPosting

    // One replacement's state, cleared by `focusInfo` and `endReplacement`.
    private var element: (any AXTextElement)?
    /// True only after `focusInfo` read a focused element that is neither secure nor composing.
    private var focusIsSafe = false
    /// The range `readRunBeforeCaret` found; the next AX write targets it.
    private var pendingRange: TextRange?
    private(set) var wordBeforeCaret: String?

    /// P2-59c: the element `focusInfo` read as safe, for the undo record's same-element check (identity only).
    var focusedElement: (any FocusedElementIdentity)? { focusIsSafe ? element : nil }

    init(focusProvider: any FocusedElementProviding, poster: any KeyEventPosting) {
        self.focusProvider = focusProvider
        self.poster = poster
    }

    func endReplacement() {
        element = nil
        focusIsSafe = false
        pendingRange = nil
        wordBeforeCaret = nil
    }

    // MARK: - Focus

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
        guard case .success(let el) = focusProvider.focusedTextElement(timeout: timeout) else { return nil }
        do {
            // A focused element without a role is something AX can't describe: refuse (001 §12 T4).
            guard let role = try optional(el.string(.role)) else { return nil }
            let subrole = try optional(el.string(.subrole))
            // Secure first, and read nothing else from a password field.
            if role == FocusInfo.secureTextFieldRole || subrole == FocusInfo.secureTextFieldRole {
                return FocusInfo(role: role, isSecure: true, hasMarkedText: false, selTextSettable: false,
                                 selRangeSettable: false, selection: nil)
            }
            if try isComposing(el) {
                return FocusInfo(role: role, isSecure: false, hasMarkedText: true, selTextSettable: false,
                                 selRangeSettable: false, selection: nil)
            }
            let selection = try optional(el.string(.selectedText))
            let range = try currentSelectedRange(el)
            let textSettable = try optional(el.isSettable(.selectedText)) ?? false
            let rangeSettable = (try optional(el.isSettable(.selectedTextRange)) ?? false) && range != nil
            var readsCaret = false
            if let range, range.isCaret, range.location > 0 {
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
    private func isComposing(_ el: any AXTextElement) throws -> Bool {
        switch el.range(.markedTextRange) {
        case .success(let r): if r.length > 0 { return true }
        case .failure(let e):
            if e.abortsFocusRead { throw Abort() }
            if e == .failed { return true }
        }
        switch el.string(.webKitMarkedText) {
        case .success(let s): return !s.isEmpty
        case .failure(let e):
            if e.abortsFocusRead { throw Abort() }
            return e == .failed
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
        case .axReadRunBeforeCaret: return .unavailable
        case .pasteboard, .keyCodesAfterSwitch: return .unavailable   // P3 / P4: not in the MVP
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
        let outcome = axWrite(el, old: old, new: new, verify: verify, select: pending)
        if outcome.verdict == .done {
            collapseSelection(el, to: pending.location + new.utf16.count)
        } else if outcome.fieldUntouched {
            // P2-59 (001 §12.3 X4): untouched only with the caret verified back where the user left it. If the run
            // were still selected, a key fallback's Backspace would delete it all and then N − 1 more before it.
            if !collapseSelection(el, to: pending.end) {
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
        guard textThere == new, case .success(let sel) = el.range(.selectedTextRange) else { return false }
        return sel == TextRange(location: written.end, length: 0) || sel == written
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
              let events = KeyStrokeComposer.typing(new) else { return .unavailable }
        return post(events)
    }

    /// R5 §B: Backspace × graphemes on screen, then type. `old`, when given, must render to exactly `count`
    /// graphemes, so a mismatch upstream never deletes the wrong amount.
    private func backspaceAndType(count: Int, old: String, new: String) -> StepOutcome {
        if !old.isEmpty && old.count != count { return .unavailable }
        guard let deletes = KeyStrokeComposer.backspaces(count),
              let typing = KeyStrokeComposer.typing(new) else { return .unavailable }
        return post(deletes + typing)
    }

    /// P2-59 (001 §12.3 X4): one `AXStringForRange` read of `[max(0, caret − maxChars), caret)`, then `locate`
    /// finds the run in it; its range is remembered for the AX write that follows. Writes nothing.
    func readRunBeforeCaret(maxChars: Int, locate: (BeforeCaretWindow) -> RunLocation?) -> StepOutcome {
        pendingRange = nil
        wordBeforeCaret = nil
        guard focusIsSafe, let el = element, maxChars > 0, let caret = try? currentSelectedRange(el),
              caret.isCaret, caret.location > 0 else { return .unavailable }
        let start = max(0, caret.location - maxChars)
        let window = TextRange(location: start, length: caret.location - start)
        // The read must return exactly the window, or the offsets mean nothing.
        guard case .success(let text) = el.string(in: window), text.utf16.count == window.length else {
            return .unavailable
        }
        let read = StepOutcome(verdict: .done, fieldUntouched: true)
        guard let run = locate(BeforeCaretWindow(text: text, location: start, reachesFieldStart: start == 0)) else {
            return read   // read fine, nothing there
        }
        // Defence in depth: the run ends at the caret, lies inside the window, starts and ends on scalar boundaries
        // (a split surrogate would decode to U+FFFD), and holds no control character (§12 T2, X3).
        let units = Array(text.utf16)
        guard run.offset >= 0, run.length > 0, run.offset + run.length == units.count else { return .unavailable }
        let slice = units[run.offset...]
        let runText = String(decoding: slice, as: UTF16.self)
        guard Array(runText.utf16) == Array(slice), !ReplacementPlanner.containsUnsafeCharacter(runText) else {
            return .unavailable
        }
        pendingRange = TextRange(location: start + run.offset, length: run.length)
        wordBeforeCaret = runText
        return read
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
