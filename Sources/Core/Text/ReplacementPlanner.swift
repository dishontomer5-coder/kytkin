// P2-13: Chooses the replacement chain (001 §2.2/§3c, R5 "Recommended fallback chains"). Pure.
//
//   selection            → AX write + read-back → type over the selection → (P3, opt-in) pasteboard
//                          (P2-36: refused in terminals; a selection with Cc/Zl/Zp is never typed over or pasted)
//   run (P2-59, nothing selected)
//     readable field     → AX read of the run before the caret → AX write + read-back → backspace × N + type
//                          (the key step only when there is a buffer run; the chain runs it only if the AX write
//                          left the field untouched and the AX run is exactly the buffer's text, 001 §12.3 X4)
//     unreadable/keysOnly/terminal → backspace × N + type over the whole buffer → refuse (beep)
//   auto-fix / undo (P4) → backspace × N + type (never AX, never the pasteboard)
//
// Hard rules checked first, for every kind: never plan anything for a secure field, while an IME is
// composing, or when the focus facts are unknown (so neither can be ruled out).

import Foundation

enum ReplacementPlanner {
    /// P2-59 (001 §12.3 X2): the run read looks back at most this many UTF-16 units; the run is at most this window.
    static let maxRunReadChars = 256

    /// - Parameters:
    ///   - focus: nil when AX couldn't read the focused element (no permission, timeout).
    ///   - allowPasteboard: P3 opt-in. Until then the pasteboard step is never planned.
    static func plan(_ r: ReplacementRequest, caps: ReplacementCapabilities, focus: FocusInfo?,
                     allowPasteboard: Bool = false) -> ReplacementPlan {
        let hint = caps.method(for: r.bundleID)
        if hint == .disabled { return .refuse(.disabledForApp) }
        guard let f = focus else { return .refuse(.focusUnknown) }
        if f.isSecure || f.role == FocusInfo.secureTextFieldRole { return .refuse(.secureField) }
        if f.hasMarkedText { return .refuse(.composing) }

        // AX writes: not for keys-only or terminal apps, only when both attributes are settable, and not after
        // a failed read-back in this app this session.
        let axWrite = hint != .keysOnly && hint != .terminal && f.selTextSettable && f.selRangeSettable
            && !caps.isAXWriteBroken(for: r.bundleID)
        // Typing needs the app to honour the Unicode string in key events.
        let canType = hint != .noUnicode
        // P2-36 (001 §12 T3): keysOnly allows the opt-in paste (⌘V is a key). Never paste in terminals
        // (bracketed paste, R5) or remote/VM apps.
        let canPaste = allowPasteboard && hint != .terminal && hint != .noUnicode

        switch r.kind {
        case .convertSelection:
            // P2-36 (001 §12 T1): a terminal selection is display only; typing "over" it types at the prompt.
            if hint == .terminal { return .refuse(.terminalSelection) }
            guard let sel = f.selection, !sel.isEmpty else { return .refuse(.selectionUnreadable) }
            // P2-36 (001 §12 T2): never type (or paste) a line break, tab or other control character. Only a
            // verified AX write may replace such a selection.
            let safe = !containsUnsafeCharacter(sel)
            var chain: [ReplacementStep] = []
            if safe && canPaste && hint == .preferPaste { chain.append(.pasteboard) }
            if axWrite { chain.append(.axWriteSelection(verify: true)) }
            if safe && canType { chain.append(.typeOverSelection) }
            if safe && canPaste && hint != .preferPaste { chain.append(.pasteboard) }
            if chain.isEmpty { return .refuse(safe ? .noMethod : .unsafeSelection) }
            return .steps(chain)

        case .convertRun:
            // P2-59 (001 §12.3 X4): AX first in readable fields, even with a valid buffer: only AX sees further back
            // than the buffer, and its write is verified. keysOnly and terminal apps never read through AX.
            let keys = canType ? bufferedRunLength(r) : nil   // nil: no buffer run, dead key or combining mark (X5)
            if axWrite && f.canReadBeforeCaret {
                var s: [ReplacementStep] = [.axReadRunBeforeCaret(maxChars: maxRunReadChars),
                                            .axWriteSelection(verify: true)]
                if let n = keys { s.append(.backspaceAndType(count: n)) }
                return .steps(s)
            }
            if let n = keys { return .steps([.backspaceAndType(count: n)]) }   // the whole buffer
            return .refuse(hasRun(r.snapshot) ? .noMethod : .bufferStale)

        case .autoFix:
            guard let n = bufferedLength(r) else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)

        case .undoFix:
            // The undo deletes the fix + its trigger, which the controller counts; no word buffer is needed.
            guard let n = r.typedLength, n > 0 else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)
        }
    }

    /// P2-36 (001 §12 T2): true if the text holds a Cc (newline, tab, CR, ESC…), Zl (U+2028) or Zp (U+2029)
    /// scalar, any of which could send a message or run a command if typed.
    static func containsUnsafeCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// P2-59 (X5): the backspace count for the whole buffer run (words and the spaces between them), else nil.
    /// The controller sets `typedLength` from `LayoutSnapshot.typedRun`, nil when the screen can't be counted.
    private static func bufferedRunLength(_ r: ReplacementRequest) -> Int? {
        guard let s = r.snapshot, hasRun(s), s.isValid || s.strokes.isEmpty,
              let n = r.typedLength, n > 0 else { return nil }
        return n
    }

    /// 001 §12.3 X5's `WordSnapshot.hasRun` (added by P2-59a), computed here from the fields that exist today.
    private static func hasRun(_ s: WordSnapshot?) -> Bool {
        guard let s else { return false }
        return !s.strokes.isEmpty || !s.previousWords.isEmpty
    }

    /// The backspace count when the buffer is exactly what's before the caret, else nil.
    private static func bufferedLength(_ r: ReplacementRequest) -> Int? {
        guard let s = r.snapshot, s.isValid, !s.strokes.isEmpty, let n = r.typedLength, n > 0 else { return nil }
        return n
    }
}
