// P2-13: Chooses the replacement chain (001 §2.2/§3c, R5 "Recommended fallback chains"). Pure.
//
//   selection            → AX write + read-back → type over the selection → (P3, opt-in) pasteboard
//   last word, valid     → backspace × N + type
//   last word, stale     → AX read before the caret → AX write + read-back → refuse (beep)
//   auto-fix / undo (P4) → backspace × N + type (never AX, never the pasteboard)
//
// Hard rules checked first, for every kind: never plan anything for a secure field, while an IME is
// composing, or when the focus facts are unknown (so neither can be ruled out).

import Foundation

enum ReplacementPlanner {
    /// R5: the stale-buffer AX read looks back at most this far (it scans back to whitespace only).
    static let maxCharsBeforeCaret = 64

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

        // AX writes: not for keys-only apps, only when both attributes are settable, and not after a
        // failed read-back in this app this session.
        let axWrite = hint != .keysOnly && f.selTextSettable && f.selRangeSettable
            && !caps.isAXWriteBroken(for: r.bundleID)
        // Typing needs the app to honour the Unicode string in key events.
        let canType = hint != .noUnicode
        // Never paste in keys-only apps (terminals: bracketed paste, R5) or remote/VM apps.
        let canPaste = allowPasteboard && hint != .keysOnly && hint != .noUnicode

        switch r.kind {
        case .convertSelection:
            guard let sel = f.selection, !sel.isEmpty else { return .refuse(.selectionUnreadable) }
            var chain: [ReplacementStep] = []
            if canPaste && hint == .preferPaste { chain.append(.pasteboard) }
            if axWrite { chain.append(.axWriteSelection(verify: true)) }
            if canType { chain.append(.typeOverSelection) }
            if canPaste && hint != .preferPaste { chain.append(.pasteboard) }
            return chain.isEmpty ? .refuse(.noMethod) : .steps(chain)

        case .convertLastWord:
            if canType, let n = bufferedLength(r) { return .steps([.backspaceAndType(count: n)]) }
            // Stale buffer (or the app ignores Unicode): find the word through AX, then write it through AX.
            if axWrite && f.canReadBeforeCaret {
                return .steps([.axReadBeforeCaret(maxChars: maxCharsBeforeCaret), .axWriteSelection(verify: true)])
            }
            return .refuse(bufferedLength(r) == nil ? .bufferStale : .noMethod)

        case .autoFix:
            guard let n = bufferedLength(r) else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)

        case .undoFix:
            // The undo deletes the fix + its trigger, which the controller counts; no word buffer is needed.
            guard let n = r.typedLength, n > 0 else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)
        }
    }

    /// The backspace count when the buffer is exactly what's before the caret, else nil.
    private static func bufferedLength(_ r: ReplacementRequest) -> Int? {
        guard let s = r.snapshot, s.isValid, !s.strokes.isEmpty, let n = r.typedLength, n > 0 else { return nil }
        return n
    }
}
