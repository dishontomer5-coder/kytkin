// P3-6: The browser's AX tree as plain values, read-only (001 §14.2, §14.3.2, D8). The read strategies are pure
// Core over this seam, so they are unit-tested on fake trees shaped like the R3b dumps; System/Browser's
// `AXElementTree` (P3-10) only translates `AXUIElement` calls, sets the 0.25 s messaging timeout on every element
// it hands out, and never sets an attribute or performs an action (never AXEnhancedUserInterface or
// AXManualAccessibility: R3b rule 1). AX thread only.
//
// R3b quirks every strategy must live with (fixtures in the tests reproduce them):
// - Zen: the content `AXWebArea` is NOT in its parent's `AXChildren`, and neither is the window, so a top-down scan
//   never finds it; it is reachable only by walking `AXParent` up from the focused element.
// - Zen: the app's `AXWindows` is empty, while `AXMainWindow`/`AXFocusedWindow` work. So there is no `windows()`
//   call here: the reader uses the main window, else a standard focused window.
// - Chrome: the focused window can be an `AXUnknown` popup: prefer the main window.
// No hit test: §14.3.3 never uses one (R3b's only hit test landed on another app's window).

enum AXReadError: Error, Sendable, Equatable {
    case timedOut        // kAXErrorCannotComplete after the 0.25 s messaging timeout: the browser is hung or busy
    case invalidElement  // the element went away (tab closed, page reloaded): drop the handle, rescan once
    case apiDisabled     // Accessibility was revoked
    case cannotComplete  // P3-10: the live tree never produces it (it maps kAXErrorCannotComplete to .timedOut)
    case other
}

enum AXStringAttribute: Sendable, Equatable {
    case role, subrole, domIdentifier, identifier, description, title, value
}

/// Role and id strings the browser reads compare against (R3, R3b).
enum AXRoleName {
    static let webArea = "AXWebArea"
    static let window = "AXWindow"
    static let standardWindow = "AXStandardWindow"
    static let textField = "AXTextField"
    static let comboBox = "AXComboBox"
    static let searchField = "AXSearchField"
    static let textArea = "AXTextArea"
    /// Roles whose focus means "the user is typing outside the page" (§14.3.3 prelude step 2).
    static let editing: Set<String> = [textField, comboBox, searchField, textArea]
}

protocol AXNodeReading {
    associatedtype Node
    func focusedElement() throws(AXReadError) -> Node?
    func mainWindow() throws(AXReadError) -> Node?
    func focusedWindow() throws(AXReadError) -> Node?
    func parent(of n: Node) throws(AXReadError) -> Node?
    func children(of n: Node) throws(AXReadError) -> [Node]
    func string(_ a: AXStringAttribute, of n: Node) throws(AXReadError) -> String?
    /// AXURL's absoluteString. The caller hands it to `SiteReader` in the same expression and keeps nothing.
    func url(of n: Node) throws(AXReadError) -> String?
    func isFocused(_ n: Node) throws(AXReadError) -> Bool?
    /// AXSize width × height.
    func area(of n: Node) throws(AXReadError) -> Double?
    /// CFEqual.
    func isSame(_ a: Node, _ b: Node) -> Bool
}
