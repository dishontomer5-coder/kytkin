// P2-18: The AX attributes the text replacer reads or writes (001 §2.2, R5 §A). The System adapter maps each
// case to its AX name; Core only names them.

import Foundation

enum AXTextAttribute: String, Sendable, CaseIterable {
    case role = "AXRole"
    case subrole = "AXSubrole"
    /// The whole text. Only read as a read-back fallback; never written (R5: it drops rich content).
    case value = "AXValue"
    case selectedText = "AXSelectedText"
    case selectedTextRange = "AXSelectedTextRange"
    case numberOfCharacters = "AXNumberOfCharacters"
    /// Cocoa's IME composition range (R5). A non-empty range means the user is composing.
    case markedTextRange = "AXTextInputMarkedRange"
    /// WebKit's composition. The adapter reads it as the text inside `AXTextInputMarkedTextMarkerRange`.
    case webKitMarkedText = "AXTextInputMarkedTextMarkerRange"
}
