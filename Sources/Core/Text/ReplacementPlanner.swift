// P2-13: Chooses the replacement chain (001 §2.2/§3c, R5 "Recommended fallback chains"). Pure.
//
//   selection            → AX write + read-back → type over the selection → (P3, opt-in) pasteboard
//                          (P2-36: refused in terminals; a selection with Cc/Zl/Zp is never typed over or pasted)
//   run (P2-59, nothing selected)
//     readable field     → AX read of the whole text box (P3-35; was the run before the caret) → AX write +
//                          read-back → backspace × N + type
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
    /// P3-33 (owner 2026-11-11): 256 → 4,096 and the run now crosses line breaks, so "the whole wrong-language run"
    /// is converted in practice (a long email paragraph or several chat lines). Still a cap, for speed and to bound
    /// one double-Shift on an all-one-language field: one AX read, a scan of ≤ 4,096 graphemes (a few ms) and one AX
    /// write. At the cap the run is cut at a word boundary (X1 step 6), as before.
    static let maxRunReadChars = 4096
    /// P3-33: if the first window read fails or comes back with the wrong length (WebKit/Chromium can count far
    /// text, e.g. attachments or block breaks, differently), the read is retried once per smaller window, nearest
    /// the caret first, so a convert still turns the tail that can be read instead of falling back to the buffer.
    static let runReadRetryChars = [1024, 256]
    /// P3-35 (owner 2026-11-11, 001 §12.3 X11): double-Shift with nothing selected converts the whole text box, read in
    /// one AX call when it is ≤ this many UTF-16 units (about 2,500 words, several pages of an email). Why 16,384: one
    /// `AXStringForRange` of 32 KB, a linear scan of ≤ 16 k graphemes (a few ms), one AX write of at most the same and
    /// its read-back stay well inside the 400 ms convert budget (B5) in a healthy Cocoa/WebKit field, and each AX call
    /// is still bounded by the 0.25 s messaging timeout; much larger values make the read and the write the slow part
    /// in WebKit and risk the budget. A bigger box: a window of this size around the caret, cut at word boundaries
    /// (`BoxConversion` step 2).
    static let maxFieldReadChars = 16_384
    /// P3-35: if the box read fails or comes back the wrong length, retry with these windows around the caret.
    static let fieldReadRetryChars = [4096, 1024, 256]

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
        let axWrite = writesThroughAX(bundleID: r.bundleID, hint: hint, caps: caps, focus: f)
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
            // P3-35: the read is the whole text box (`axReadField`), no longer the run before the caret.
            if axWrite && f.canReadBeforeCaret {
                var s: [ReplacementStep] = [.axReadField(maxChars: maxFieldReadChars),
                                            .axWriteSelection(verify: true)]
                if let n = keys { s.append(.backspaceAndType(count: n)) }
                return .steps(s)
            }
            if let n = keys { return .steps([.backspaceAndType(count: n)]) }   // the whole buffer
            return .refuse(r.snapshot?.hasRun == true ? .noMethod : .bufferStale)

        case .autoFix:
            guard let n = bufferedLength(r) else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)

        case .undoFix:
            // The undo deletes the fix + its trigger, which the controller counts; no word buffer is needed.
            guard let n = r.typedLength, n > 0 else { return .refuse(.bufferStale) }
            return canType ? .steps([.backspaceAndType(count: n)]) : .refuse(.noMethod)
        }
    }

    private static func writesThroughAX(bundleID: String, hint: MethodHint, caps: ReplacementCapabilities,
                                        focus f: FocusInfo) -> Bool {
        hint != .keysOnly && hint != .terminal && f.selTextSettable && f.selRangeSettable
            && !caps.isAXWriteBroken(for: bundleID)
    }

    /// P3-37: a double-Shift with nothing selected reads (and writes) this box through AX, the `.convertRun` plan's
    /// first branch. False = the app's box can't be read: the buffer, or (P3-37 (c)) the clipboard.
    static func readsField(bundleID: String, caps: ReplacementCapabilities, focus f: FocusInfo) -> Bool {
        let hint = caps.method(for: bundleID)
        guard hint != .disabled else { return false }
        return writesThroughAX(bundleID: bundleID, hint: hint, caps: caps, focus: f) && f.canReadBeforeCaret
    }

    /// P3-40 (b): a selection is replaced through AX here (the `.convertSelection` plan's AX write). False = it would be
    /// typed over from AX's selected text, which in Chromium/Electron may have lost its line breaks: the clipboard
    /// copies it instead (ConvertController).
    static func writesSelection(bundleID: String, caps: ReplacementCapabilities, focus f: FocusInfo) -> Bool {
        let hint = caps.method(for: bundleID)
        guard hint != .disabled else { return false }
        return writesThroughAX(bundleID: bundleID, hint: hint, caps: caps, focus: f)
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

    /// P3-33: a line-break scalar: LF, VT, FF, CR, NEL, U+2028, U+2029. A run read through AX may cross these (the
    /// AX write puts them back unchanged); they are still never typed (`containsUnsafeCharacter`).
    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// P3-33: true if the text holds a control character other than a line break (tab, ESC, NUL…): a run never
    /// crosses one (a tab often separates fields; other controls are never plain prose).
    static func containsHardStop(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            !isLineBreak($0) && containsUnsafeCharacter(String($0))
        }
    }

    /// P3-35: true if the text holds a control character other than a line break or a tab. A whole-box write may
    /// cross line breaks and tabs (it puts them back unchanged); other controls (ESC, NUL…) bound what converts.
    static func containsFieldStop(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 != "\t" && !isLineBreak($0) && containsUnsafeCharacter(String($0)) }
    }

    /// P2-59 (X5): the backspace count for the whole buffer run (words and the spaces between them), else nil.
    /// The controller sets `typedLength` from `LayoutSnapshot.typedRun`, nil when the screen can't be counted.
    private static func bufferedRunLength(_ r: ReplacementRequest) -> Int? {
        guard let s = r.snapshot, s.hasRun, s.isValid || s.strokes.isEmpty,
              let n = r.typedLength, n > 0 else { return nil }
        return n
    }

    /// The backspace count when the buffer is exactly what's before the caret, else nil.
    private static func bufferedLength(_ r: ReplacementRequest) -> Int? {
        guard let s = r.snapshot, s.isValid, !s.strokes.isEmpty, let n = r.typedLength, n > 0 else { return nil }
        return n
    }
}
