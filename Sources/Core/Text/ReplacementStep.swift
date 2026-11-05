// P2-13: One step of a text-replacement chain (001 §2.2, R5). The planner returns these in order; the
// System `TextReplacer` (P2-18) executes them until one reports `.done`.

import Foundation

enum ReplacementStep: Sendable, Equatable {
    /// AX: set the selected range, then `AXSelectedText`, then read back. AX "success" is not proof (R5).
    case axWriteSelection(verify: Bool)
    /// Post the converted text as Unicode key events; typing replaces the current selection.
    case typeOverSelection
    /// Backspace × `count`, then type. `count` = grapheme clusters of what is on screen now (R5 "counting").
    case backspaceAndType(count: Int)
    /// Stale buffer: read ≤ `maxChars` before the caret through AX and scan back to whitespace only.
    /// It selects nothing by itself; the next step writes over the range it found.
    case axReadBeforeCaret(maxChars: Int)
    /// P3: opt-in pasteboard step (snapshot → ⌘V → restore). Never planned for keys-only apps (terminals).
    case pasteboard
    /// P4: post key codes after switching the input source, for apps that ignore Unicode key events.
    case keyCodesAfterSwitch
}
