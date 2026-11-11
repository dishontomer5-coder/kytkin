// P2-12: A copy of the word buffer handed to a convert / auto-fix worker (001 §2.2). Strokes only, never text.
// Made only on a trigger, so the allocation stays off the per-key path (B1).
// P2-59 (001 §12.3 X5/X6): it also carries the spaces between the words, so the whole buffer (the key-path run) can be
// rendered and counted, and the last finished convert generation that nothing has touched since.

import Foundation

struct WordSnapshot: Sendable, Equatable {
    /// The current word (since the last whitespace), oldest stroke first.
    let strokes: [Stroke]
    /// The words before it since the last reset, oldest first (P3-33: no word limit; ≤ `WordBuffer.maxStrokes` keys).
    let previousWords: [[Stroke]]
    /// The layout the strokes were typed in, as far as the processor knows. P2-59: after a convert that kept the buffer
    /// without switching, the layout the kept buffer is rendered in (`bufferRenderedIn`).
    let renderedIn: InputSourceID?
    /// True when `strokes` is non-empty and exactly what the user typed before the caret since the last reset.
    /// P2-59: unchanged meaning (the current word), kept for P4's auto-fix.
    let isValid: Bool
    /// P2-59 (X5): `gaps.count == previousWords.count`; `gaps[i]` = spaces typed after `previousWords[i]`. The last one
    /// is trailing (right before the caret) when `strokes` is empty. Buffer text = `w0 + " "×g0 + w1 + … + current`.
    let gaps: [Int]
    /// P2-59 (X6): the generation of the last convert the processor finished (not aborted), while no key, click, reset
    /// or buffer invalidation happened since. Nil otherwise.
    let untouchedSinceConvert: UInt64?

    /// P2-59 (X5): the buffer holds something before the caret: a current word, or earlier words (with their spaces).
    var hasRun: Bool { !strokes.isEmpty || !previousWords.isEmpty }

    init(strokes: [Stroke], previousWords: [[Stroke]], renderedIn: InputSourceID?, isValid: Bool,
         gaps: [Int]? = nil, untouchedSinceConvert: UInt64? = nil) {
        self.strokes = strokes
        self.previousWords = previousWords
        self.renderedIn = renderedIn
        self.isValid = isValid
        // P2-59: a caller that predates `gaps` (fixtures) means one space after each earlier word.
        let g = gaps ?? Array(repeating: 1, count: previousWords.count)
        assert(g.count == previousWords.count, "P2-59: one gap per earlier word")
        self.gaps = g
        self.untouchedSinceConvert = untouchedSinceConvert
    }
}

/// P2-59c (001 §12.3 X5): the snapshot is the key path's run, so `LayoutSnapshot.typedRun(snap, in:)` reads it directly.
extension WordSnapshot: BufferedRun {}
