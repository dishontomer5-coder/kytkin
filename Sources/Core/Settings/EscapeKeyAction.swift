// P3-12 (P2-63): What Esc does in Kytkin's windows (`KytkinWindow.cancelOperation`), narrowed to the standard macOS
// behaviour. Esc used to close the window whatever had focus, so Esc in the Rules search box closed Settings and lost
// the filter. Now, as in other Mac apps, Esc first undoes the typing context, and closes the window only when nothing
// is being edited:
// - a sheet or dialog is attached to the window → leave it alone (Esc is the sheet's own Cancel);
// - a search field with text → clear it;
// - P3-15 (P3-12 QA note): any other one-line field (e.g. an address the user is typing) → stop editing, never clear:
//   Esc must not throw away what was typed. Only search fields are cleared;
// - an empty search field, or a multi-line text area → stop editing (focus leaves the field, nothing is lost);
// - nothing being edited → close the window.
// So from a search field with text: Esc clears it, Esc leaves the field, Esc closes the window.
// An open pop-up list (a picker) handles Esc itself in its own menu loop and never gets here.

import Foundation

enum EscapeKeyAction: Equatable, Sendable {
    case ignore
    case clearField
    case stopEditing
    case closeWindow

    /// What has the keyboard in the window when Esc arrives.
    enum Focus: Equatable, Sendable {
        case nothingEdited
        /// A search field being edited (its field editor belongs to an NSSearchField). Esc clears it.
        case searchField(isEmpty: Bool)
        /// Any other one-line text field being edited. P3-15: never cleared by Esc.
        case textField
        /// A multi-line editable text view. Never cleared by Esc.
        case textArea
    }

    static func decide(sheetAttached: Bool, focus: Focus) -> EscapeKeyAction {
        if sheetAttached { return .ignore }
        switch focus {
        case .nothingEdited: return .closeWindow
        case .searchField(let isEmpty): return isEmpty ? .stopEditing : .clearField
        case .textField, .textArea: return .stopEditing
        }
    }
}
