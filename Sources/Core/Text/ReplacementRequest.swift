// P2-13: What a controller wants replaced (001 §2.2). Built on @TextActor from a KeySignal and FocusInfo.

import Foundation

struct ReplacementRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Double-Shift with a selection.
        case convertSelection
        /// P2-59 (001 §12.3): double-Shift with no selection: the run before the caret, through AX in readable
        /// fields, else the whole word buffer by keys.
        case convertRun
        /// P4: the word that just ended was typed in the wrong layout.
        case autoFix
        /// P4: Backspace right after a fix.
        case undoFix
    }

    let kind: Kind
    let bundleID: String
    /// The word buffer at the trigger. nil or `isValid == false` = stale.
    let snapshot: WordSnapshot?
    /// 001 field, informational: the planner reads the selection itself from `FocusInfo.selection`.
    let selectionLength: Int?
    /// P2-13: grapheme clusters currently on screen for the buffered text (the `render` of the snapshot in
    /// its current layout; for undo, the fix + its trigger). Needed for `backspaceAndType(count:)`.
    /// P2-59 (X5): for `.convertRun`, the graphemes of `LayoutSnapshot.typedRun`, or nil when there is no buffer run
    /// (or it holds a dead key or a combining mark).
    let typedLength: Int?

    init(kind: Kind, bundleID: String, snapshot: WordSnapshot? = nil, selectionLength: Int? = nil,
         typedLength: Int? = nil) {
        self.kind = kind
        self.bundleID = bundleID
        self.snapshot = snapshot
        self.selectionLength = selectionLength
        self.typedLength = typedLength
    }
}
