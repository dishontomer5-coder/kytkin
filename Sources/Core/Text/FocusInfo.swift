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

    init(role: String?, isSecure: Bool, hasMarkedText: Bool, selTextSettable: Bool, selRangeSettable: Bool,
         selection: String?, canReadBeforeCaret: Bool = false) {
        self.role = role
        self.isSecure = isSecure
        self.hasMarkedText = hasMarkedText
        self.selTextSettable = selTextSettable
        self.selRangeSettable = selRangeSettable
        self.selection = selection
        self.canReadBeforeCaret = canReadBeforeCaret
    }

    /// The AX role of a password field.
    static let secureTextFieldRole = "AXSecureTextField"
}
