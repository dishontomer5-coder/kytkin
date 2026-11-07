// P2-59: What one grapheme says about the run before the caret (001 §12.3 X1). Pure; holds no text.
// `LayoutSnapshot.runClass(of:)` answers it from the pair's two reverse indexes; `RunBeforeCaret.scan` walks it.

import Foundation

/// One side of the active pair: `pair.a` or `pair.b`.
enum PairSide: Sendable, Equatable {
    case a, b

    var other: PairSide { self == .a ? .b : .a }
}

enum RunCharClass: Sendable, Equatable {
    /// Any scalar is Cc, Zl or Zp (newline, CR, CRLF, tab, U+2028/2029): `ReplacementPlanner.containsUnsafeCharacter`.
    /// The run never crosses one (X3).
    case hardStop
    /// `Character.isWhitespace` and not a hard stop (space, no-break space).
    case space
    /// Only that side's layout types it. P2-60 QA: on Apple Hebrew / ABC that includes non-letters (ASCII `'` `"` vs
    /// `׳` `״`); `RunBeforeCaret` lets only letters pick the side or start a run.
    case strong(PairSide)
    /// Both layouts type it: digits, most punctuation, and on Apple Hebrew / ABC `,` `.` `;` `/` (`'` only on
    /// Hebrew-PC). Direction-ambiguous, converted per the run's side.
    case shared
    /// Neither layout types it and it is a letter (another script, e.g. Cyrillic in a HE/EN pair). Ends the run.
    case foreignLetter
    /// Neither layout types it and it is not a letter (emoji, symbols). Passes through unchanged.
    case foreignOther
}

/// P2-59 (001 §12.3 X5): the buffer's words and the spaces between them, as the key path needs them.
/// `gaps.count == previousWords.count`; `gaps[i]` = spaces typed after `previousWords[i]` (the last one is trailing
/// when `strokes` is empty). `WordSnapshot` conforms (P2-59c), so `LayoutSnapshot.typedRun(snap, in:)` reads as 001
/// writes it.
protocol BufferedRun {
    /// The current word, oldest stroke first.
    var strokes: [Stroke] { get }
    /// The words before it, oldest first.
    var previousWords: [[Stroke]] { get }
    var gaps: [Int] { get }
}
