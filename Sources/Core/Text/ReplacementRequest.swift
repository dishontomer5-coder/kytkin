// P2-13: What a controller wants replaced (001 §2.2). Built on @TextActor from a KeySignal and FocusInfo.

import Foundation

struct ReplacementRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Double-Shift with a selection.
        case convertSelection
        /// Double-Shift with no selection: the buffered last word, or AX before the caret if the buffer is stale.
        case convertLastWord
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
