// P3-35: no longer planned for a double-Shift (readable fields convert the whole text box, `BoxConversion`, 001 §12.3
// X11); kept with its tests for now.
// P2-59: Finds the run typed in the wrong layout before the caret (001 §12.3 X1, X2, X3). Pure; replaces the
// P2-18 `WordBeforeCaret` (whitespace-only scan). The window is the ≤ 4,096 UTF-16 units read through AX (P3-33;
// was 256); the run stops where text in the other language starts, at a foreign letter, at a hard stop (a tab or
// other non-line-break control character), or at a word it can't attribute.
// P3-33 (owner 2026-11-11): the run crosses line breaks. A `lineBreak` grapheme separates tokens exactly like a space
// (so `akuo\nvh|` is one run, and a Hebrew line above still stops it at its last Hebrew letter); it converts to itself.
//
// Tokens are maximal runs of non-separator (`space` / `lineBreak`) graphemes. A token is S if it has a `strong(S)` grapheme, weak if it has
// no strong grapheme and no foreign letter (`shared`/`foreignOther` only). The rules, in order (X1):
//   1. Hard stop: only the text after the last hard stop counts. Its start is known if a hard stop was found or the
//      window reaches the field start; otherwise the window's first token may be cut. (P3-33: no longer a line.)
//   2. Direction: from the caret back, the first token with a strong grapheme or a foreign letter decides: S = the
//      side of its last such grapheme (a foreign letter → nothing). A weak token holding a letter, or no token at
//      all → nothing. Weak tokens without letters (digits, punctuation, emoji) are crossed.
//   3. Extend: S tokens and weak tokens without letters are included; a weak token with a letter ends the run; a
//      token holding the other side or a foreign letter ends it inside the token, right after the last such grapheme.
//   4. Trim the left end: leading spaces and weak tokens go; in a token cut by step 3 the graphemes before its first
//      `strong(S)` go too (typed before the switch). A full token that starts with `,` stays (`שלום ,usv` → `,usv`).
//   5. The right end is the caret: trailing spaces and weak tokens are part of the run.
//   6. Cap: if the run took in the window's first token, which starts at the window's first grapheme, and the start
//      is not known, that token may be cut: drop it, trim again. No `strong(S)` left → `.tooLong`.
// P2-60 QA: only **letters** decide the direction and start a run. A non-letter only one layout types (on Apple
// Hebrew / ABC: ASCII `'` `"` `&` `\` `` ` `` vs `׳` `״` `₪`) still ends a run of the other side (the converter has no
// key for it, so it would pass through and not round-trip), but it never picks the side and never starts a cut token.
// Otherwise correct Hebrew such as `מס' 5 tkhk|` or `פרופ'|` (ASCII apostrophe, common in pasted text) had its `'`
// converted to `,`.
// Text is only held for the call; nothing is logged (B12).

import Foundation

/// The text before the caret, as read for one convert.
struct BeforeCaretWindow: Sendable, Equatable {
    let text: String
    /// Absolute UTF-16 offset of `text`'s first unit; the caret is at `location + text.utf16.count`.
    let location: Int
    /// `text` starts at the beginning of the field.
    let reachesFieldStart: Bool
}

/// A run inside a `BeforeCaretWindow`, in UTF-16 units relative to the window's text.
struct RunLocation: Sendable, Equatable {
    let offset: Int
    let length: Int
}

enum RunBeforeCaret {
    enum Scan: Sendable, Equatable {
        case run(RunLocation, side: PairSide)
        /// No run to convert (no strong grapheme near the caret, a word neither layout can tell, another script).
        case nothing
        /// X2: a single token longer than the window. Refused with a beep.
        case tooLong
    }

    private struct Grapheme {
        let cls: RunCharClass
        let isLetter: Bool
        /// UTF-16 offset within the window.
        let offset: Int
    }

    /// Grapheme indices, `end` exclusive.
    private struct Token {
        let start: Int
        let end: Int
        var range: Range<Int> { start..<end }
    }

    static func scan(_ w: BeforeCaretWindow, classify: (Character) -> RunCharClass) -> Scan {
        var g: [Grapheme] = []
        var units = 0
        var lineStart = 0
        var foundStop = false
        for ch in w.text {
            let cls = classify(ch)
            g.append(Grapheme(cls: cls, isLetter: ch.isLetter, offset: units))
            units += ch.utf16.count
            if cls == .hardStop {   // Step 1.
                lineStart = g.count
                foundStop = true
            }
        }
        let startKnown = foundStop || w.reachesFieldStart

        var tokens: [Token] = []
        var i = lineStart
        while i < g.count {
            if isSeparator(g[i].cls) { i += 1; continue }
            var j = i
            while j < g.count, !isSeparator(g[j].cls) { j += 1 }
            tokens.append(Token(start: i, end: j))
            i = j
        }

        guard let side = direction(tokens, g) else { return .nothing }   // Step 2.

        // Step 3. `runStart` is the first included grapheme; `cut` is a token entered by a mid-token stop.
        var runStart = g.count
        var cut: Token?
        var tookFirstToken = false
        for k in tokens.indices.reversed() {
            let t = tokens[k]
            if let stop = t.range.last(where: { endsRun(g[$0].cls, side: side) }) {
                runStart = stop + 1
                if stop + 1 < t.end { cut = Token(start: stop + 1, end: t.end) }
                break
            }
            if !hasStrong(t, side, g) && t.range.contains(where: { g[$0].isLetter }) { break }
            runStart = t.start
            if k == 0 { tookFirstToken = true }
        }

        // Step 6: the window's first token may continue before the window. Never convert a cut word.
        var capped = false
        if tookFirstToken, !startKnown, let first = tokens.first, first.start == 0 {
            runStart = first.end
            cut = nil
            capped = true
        }

        guard let start = trim(from: runStart, cut: cut, tokens: tokens, side: side, g) else {   // Step 4.
            return capped ? .tooLong : .nothing
        }
        let offset = g[start].offset
        return .run(RunLocation(offset: offset, length: units - offset), side: side)   // Steps 5, 7.
    }

    // MARK: - Private

    /// P3-33: spaces and line breaks both separate tokens; the run crosses both.
    private static func isSeparator(_ cls: RunCharClass) -> Bool {
        cls == .space || cls == .lineBreak
    }

    /// Step 2.
    private static func direction(_ tokens: [Token], _ g: [Grapheme]) -> PairSide? {
        for t in tokens.reversed() {
            if let k = t.range.last(where: { isStrongOrForeignLetter(g[$0]) }) {
                if case .strong(let side) = g[k].cls { return side }
                return nil   // a foreign letter nearest the caret: another script
            }
            if t.range.contains(where: { g[$0].isLetter }) { return nil }   // a word neither layout can tell
        }
        return nil
    }

    /// Step 4: the first grapheme of the trimmed run, or nil if no `strong(side)` grapheme is left.
    private static func trim(from runStart: Int, cut: Token?, tokens: [Token], side: PairSide,
                             _ g: [Grapheme]) -> Int? {
        if let cut, cut.start == runStart,
           let first = cut.range.first(where: { isStrongLetter(g[$0], side) }) {
            return first
        }
        let from = cut.map { $0.start == runStart ? $0.end : runStart } ?? runStart
        return tokens.first { t in t.start >= from && t.range.contains { isStrongLetter(g[$0], side) } }?.start
    }

    /// P2-60 QA: a run starts at a letter only that side types (never at a one-sided `'` or `"`).
    private static func isStrongLetter(_ x: Grapheme, _ side: PairSide) -> Bool {
        x.isLetter && x.cls == .strong(side)
    }

    private static func hasStrong(_ t: Token, _ side: PairSide, _ g: [Grapheme]) -> Bool {
        t.range.contains { g[$0].cls == .strong(side) }
    }

    /// The other side, or another script: the run stops right after it.
    private static func endsRun(_ cls: RunCharClass, side: PairSide) -> Bool {
        cls == .strong(side.other) || cls == .foreignLetter
    }

    /// Step 2. P2-60 QA: a one-sided non-letter (`'`, `"`) doesn't decide; the letters around it do.
    private static func isStrongOrForeignLetter(_ x: Grapheme) -> Bool {
        if case .strong = x.cls { return x.isLetter }
        return x.cls == .foreignLetter
    }
}
