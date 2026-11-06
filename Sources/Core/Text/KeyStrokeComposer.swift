// P2-18: Turns "delete N graphemes, then type this text" into the key events to post (R5 §B). Pure.
// Text is split into ≤ 16 UTF-16 units per event, at grapheme boundaries where possible, so a letter with
// niqqud or an emoji sequence is never split across two events.

import Foundation

enum KeyStrokeComposer {
    /// Defensive cap on backspaces in one step: the word buffer holds ≤ 64 strokes (design.md), and an undo
    /// deletes a fix plus its trigger. Anything larger is a bug upstream, never typed.
    static let maxBackspaces = 128

    /// Down + up for each of `count` Backspaces. One Backspace deletes one grapheme cluster in Cocoa (R5).
    /// nil if `count` is outside 1…`maxBackspaces`.
    static func backspaces(_ count: Int) -> [SyntheticKeyEvent]? {
        guard (1...maxBackspaces).contains(count) else { return nil }
        return (0..<count).flatMap { _ in [SyntheticKeyEvent.backspace(keyDown: true),
                                           SyntheticKeyEvent.backspace(keyDown: false)] }
    }

    /// Down + up per chunk of `text`. nil if the text is empty or holds a control or line-break character
    /// (design.md: Kytkin never types one).
    static func typing(_ text: String) -> [SyntheticKeyEvent]? {
        guard !text.isEmpty, !ReplacementPlanner.containsUnsafeCharacter(text) else { return nil }
        var events: [SyntheticKeyEvent] = []
        for chunk in chunks(text) {
            guard let down = SyntheticKeyEvent.text(chunk, keyDown: true),
                  let up = SyntheticKeyEvent.text(chunk, keyDown: false) else { return nil }
            events += [down, up]
        }
        return events
    }

    /// UTF-16 chunks of at most `SyntheticKeyEvent.maxUnicodeUnits`. Grapheme clusters stay whole; a single
    /// cluster longer than the limit (a long emoji tag sequence) is split between scalars, never inside one.
    static func chunks(_ text: String) -> [[UInt16]] {
        let limit = SyntheticKeyEvent.maxUnicodeUnits
        var out: [[UInt16]] = []
        var current: [UInt16] = []
        func flush() { if !current.isEmpty { out.append(current); current = [] } }
        for character in text {
            let units = Array(character.utf16)
            if units.count > limit {
                flush()
                for scalar in character.unicodeScalars {
                    let su = Array(String(scalar).utf16)
                    if current.count + su.count > limit { flush() }
                    current += su
                }
                flush()
            } else {
                if current.count + units.count > limit { flush() }
                current += units
            }
        }
        flush()
        return out
    }
}
