// P2-18: The stale-buffer path's word finder (R5 "Getting the text to convert"). Pure.
// Given the ≤ 64 UTF-16 units before the caret, scan back to whitespace only: on Hebrew, `,` `.` `;` are
// letters (R5 proved ⌥⇧← splits `,usv`), so punctuation never ends the word.

import Foundation

enum WordBeforeCaret {
    /// - Parameters:
    ///   - text: the text just before the caret (read with `AXStringForRange`).
    ///   - reachesFieldStart: true if `text` starts at the beginning of the field. If not, and no whitespace is
    ///     found, the word may be longer than the window, so nothing is returned (never guess a partial word).
    /// - Returns: the last word, or nil if there is none, it is cut off, or it holds a control character.
    static func lastWord(in text: String, reachesFieldStart: Bool) -> String? {
        let word: Substring
        if let space = text.lastIndex(where: { $0.isWhitespace }) {
            word = text[text.index(after: space)...]
        } else if reachesFieldStart {
            word = text[...]
        } else {
            return nil
        }
        guard !word.isEmpty, !ReplacementPlanner.containsUnsafeCharacter(String(word)) else { return nil }
        return String(word)
    }
}
