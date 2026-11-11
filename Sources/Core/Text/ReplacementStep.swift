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
    /// P2-59 (001 §12.3 X4): read ≤ `maxChars` UTF-16 units before the caret through AX and find the run in them
    /// (`RunBeforeCaret`). Read-only: it selects nothing; the next AX step writes over the range it found. Runs
    /// through `TextReplacing.readRunBeforeCaret` (its locator needs the layouts); `perform` answers `.unavailable`.
    case axReadRunBeforeCaret(maxChars: Int)
    /// P3-35 (001 §12.3 X11): read the whole text box through AX (≤ `maxChars` UTF-16 units; a bigger box → a window
    /// around the caret) and find what converts in it (`BoxConversion`). Read-only, like `axReadRunBeforeCaret`; runs
    /// through `TextReplacing.readField`, and the next AX write replaces the range it found. Since P3-35 the planner
    /// plans this one, not `axReadRunBeforeCaret`, for a double-Shift with nothing selected.
    case axReadField(maxChars: Int)
    /// P3-42 (001 §12.3 X15): the Chromium/Electron convert: read the box through `AXValue`, select each changed piece
    /// with `AXSelectedTextRange`, check it by reading `AXSelectedText` back, type over it with Unicode key events.
    /// Run by `ChromiumAXConvert`, never planned by `ReplacementPlanner` (`perform` answers `.unavailable`); it names
    /// the method in `ConvertOutcome.converted`.
    case axSelectAndType
    /// P3: opt-in pasteboard step (snapshot → ⌘V → restore). Never planned for keys-only apps (terminals).
    case pasteboard
    /// P4: post key codes after switching the input source, for apps that ignore Unicode key events.
    case keyCodesAfterSwitch
}
