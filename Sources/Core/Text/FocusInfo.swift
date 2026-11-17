// P2-13: Facts about the focused text field, read through AX by the System adapter (001 §2.2).
// Metadata only, except `selection`, which is held in memory for one convert and never logged or stored.

import Foundation

struct FocusInfo: Sendable, Equatable {
    /// AX role, e.g. "AXTextArea", "AXSecureTextField".
    let role: String?
    /// The adapter's secure-field verdict (role or subrole `AXSecureTextField`, or a password field).
    let isSecure: Bool
    /// An IME composition is in progress (marked text). Never write while composing (design.md).
    let hasMarkedText: Bool
    let selTextSettable: Bool
    let selRangeSettable: Bool
    /// The selected text, if AX could read it. nil or "" = nothing selected / unreadable.
    let selection: String?
    /// `AXStringForRange` and the caret range can be read, so the stale-buffer path can find the last word.
    let canReadBeforeCaret: Bool
    /// P3-41 QA: `isSecure` / `hasMarkedText` come only from an AX read that *failed* (P2-49 item 6 / R5: a password
    /// field or a composition can't be ruled out), not from a secure role or subrole or a real marked range. Only then
    /// may a terminal post its buffer's keys anyway (`ConvertController.terminalFallback`).
    let fromFailedRead: Bool
    /// P6-0j: the length of `AXSelectedTextRange` (UTF-16 units), nil = unreadable. Spotlight's inline completion is a
    /// selected range after the typed text (its selected text may not even read): Backspace would delete only it.
    let selectedLength: Int?
    /// P6-0j QA: the selected range starts after the field's first unit and ends at the field's end
    /// (`AXNumberOfCharacters`): the shape of an inline completion (Spotlight, Safari's address bar, search fields),
    /// which the app selects after what was typed. Ranges only, no text.
    let selectionIsFieldTail: Bool
    /// P6-0j QA: for such a tail selection, `AXStringForRange` can be read (the text before it can be converted).
    let canReadBeforeSelection: Bool

    init(role: String?, isSecure: Bool, hasMarkedText: Bool, selTextSettable: Bool, selRangeSettable: Bool,
         selection: String?, canReadBeforeCaret: Bool = false, fromFailedRead: Bool = false,
         selectedLength: Int? = nil, selectionIsFieldTail: Bool = false, canReadBeforeSelection: Bool = false) {
        self.role = role
        self.isSecure = isSecure
        self.hasMarkedText = hasMarkedText
        self.selTextSettable = selTextSettable
        self.selRangeSettable = selRangeSettable
        self.selection = selection
        self.canReadBeforeCaret = canReadBeforeCaret
        self.fromFailedRead = fromFailedRead
        self.selectedLength = selectedLength
        self.selectionIsFieldTail = selectionIsFieldTail
        self.canReadBeforeSelection = canReadBeforeSelection
    }

    /// P6-0j QA: these facts for an inline-completion convert: the selection's start is the caret (the text before it
    /// is read and converted as with nothing selected) and the selected text itself is never used.
    var beforeInlineCompletion: FocusInfo {
        FocusInfo(role: role, isSecure: isSecure, hasMarkedText: hasMarkedText, selTextSettable: selTextSettable,
                  selRangeSettable: selRangeSettable, selection: nil, canReadBeforeCaret: canReadBeforeSelection,
                  fromFailedRead: fromFailedRead, selectedLength: selectedLength,
                  selectionIsFieldTail: selectionIsFieldTail, canReadBeforeSelection: canReadBeforeSelection)
    }

    /// P6-0j: AX reports something selected in the box (a selected range, or selected text). Backspace would delete
    /// the selection first, so the blind key path (Backspace × N + type) must never run.
    var hasSelectedRange: Bool {
        (selectedLength ?? 0) > 0 || !(selection ?? "").isEmpty
    }

    /// The AX role of a password field.
    static let secureTextFieldRole = "AXSecureTextField"
}
