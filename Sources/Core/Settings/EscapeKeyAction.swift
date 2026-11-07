// P3-12 (P2-63): What Esc does in Kytkin's windows (`KytkinWindow.cancelOperation`), narrowed to the standard macOS
// behaviour. Esc used to close the window whatever had focus, so Esc in the Rules search box closed Settings and lost
// the filter. Now, as in other Mac apps, Esc first undoes the typing context, and closes the window only when nothing
// is being edited:
// - a sheet or dialog is attached to the window → leave it alone (Esc is the sheet's own Cancel);
// - a one-line text field (search, filter) with text → clear it;
// - an empty one-line field, or a multi-line text area → stop editing (focus leaves the field, nothing is lost);
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
        /// A one-line text field being edited (AppKit's field editor).
        case textField(isEmpty: Bool)
        /// A multi-line editable text view. Never cleared by Esc.
        case textArea
    }

    static func decide(sheetAttached: Bool, focus: Focus) -> EscapeKeyAction {
        if sheetAttached { return .ignore }
        switch focus {
        case .nothingEdited: return .closeWindow
        case .textField(let isEmpty): return isEmpty ? .stopEditing : .clearField
        case .textArea: return .stopEditing
        }
    }
}
