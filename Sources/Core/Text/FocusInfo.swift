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

    init(role: String?, isSecure: Bool, hasMarkedText: Bool, selTextSettable: Bool, selRangeSettable: Bool,
         selection: String?, canReadBeforeCaret: Bool = false, fromFailedRead: Bool = false,
         selectedLength: Int? = nil) {
        self.role = role
        self.isSecure = isSecure
        self.hasMarkedText = hasMarkedText
        self.selTextSettable = selTextSettable
        self.selRangeSettable = selRangeSettable
        self.selection = selection
        self.canReadBeforeCaret = canReadBeforeCaret
        self.fromFailedRead = fromFailedRead
        self.selectedLength = selectedLength
    }

    /// P6-0j: AX reports something selected in the box (a selected range, or selected text). Backspace would delete
    /// the selection first, so the blind key path (Backspace × N + type) must never run.
    var hasSelectedRange: Bool {
        (selectedLength ?? 0) > 0 || !(selection ?? "").isEmpty
    }

    /// The AX role of a password field.
    static let secureTextFieldRole = "AXSecureTextField"
}
