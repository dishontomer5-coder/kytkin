// P2-12: A copy of the word buffer handed to a convert / auto-fix worker (001 §2.2). Strokes only, never text.
// Made only on a trigger, so the allocation stays off the per-key path (B1).

import Foundation

struct WordSnapshot: Sendable, Equatable {
    /// The current word (since the last whitespace), oldest stroke first.
    let strokes: [Stroke]
    /// Up to 2 words before it, oldest first.
    let previousWords: [[Stroke]]
    /// The layout the strokes were typed in, as far as the processor knows.
    let renderedIn: InputSourceID?
    /// True when `strokes` is non-empty and exactly what the user typed before the caret since the last reset.
    let isValid: Bool
}
