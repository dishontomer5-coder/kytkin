// P3-35 (owner 2026-11-11, plan.md P3-35; 001 §12.3 X11): with nothing selected, double-Shift converts the whole text
// box. Pure; replaces `RunBeforeCaret` for readable fields. Text is only held for the call; nothing is logged (B12).
//
//   1. Segment. Line breaks and tabs are crossed (they separate words and are written back unchanged). Any other
//      control character (ESC, NUL…) bounds the part of the box that converts: the segment holding the caret.
//   2. Window edges. If the window doesn't reach the field's start (end), its first (last) word may be cut: it is
//      left alone. The end at the caret is never trimmed (the caret is where the user stopped typing).
//   3. Direction S: the nearest letter before the caret; none → the nearest letter after it. It must be a letter
//      only one layout of the pair types (`strong`, P2-60: a one-sided `'` or `"` never decides); a letter of
//      another script, or one both layouts type (same-script pairs), → nothing to convert (double-Shift switches).
//   4. Per character, every letter of S anywhere in the segment converts to the other layout. Letters of the other
//      layout, other scripts, spaces, line breaks, tabs, digits and emoji stay as they are.
//   5. Shared and one-sided punctuation (P2-60 letters-only rule). A non-letter that S's layout types (`shared`, such
//      as `,` `.` `;` `/` on Apple Hebrew / ABC, or a one-sided `strong(S)` such as ASCII `'` `"`) converts only when
//      its role is unambiguous: inside a word (a run between spaces / line breaks / tabs), the nearest letter on
//      each side that is in the pair or another script is a letter of S or there is none, and at least one side has
//      one. So `vh,` → `הית` and `,usv` → `תודה`, but `מס'`, `שלום, מה.` and `"שלום"` keep their punctuation (a
//      Hebrew letter is next to it), and a lone `,` or `-` between spaces stays. Letters both layouts type are
//      transparent to that test.
//   6. The write is one range: from the first to the last character that changes (unchanged text in between is
//      written back as it was). The caret stays where it was, moved only by a length change before it.

import Foundation

enum BoxConversion {
    /// One planned whole-box convert.
    struct Plan: Sendable, Equatable {
        let edit: FieldEdit
        /// The replacement for `edit`'s range.
        let text: String
        /// The side converted from (the text written is on `side.other`).
        let side: PairSide
    }

    enum Result: Sendable, Equatable {
        case convert(Plan)
        /// No letter to decide the direction, or nothing would change.
        case nothing
        /// The window was cut on both sides of one word bigger than it: nothing can be converted whole. Beeps.
        case tooLong
    }

    private struct Grapheme {
        let cls: RunCharClass
        let isLetter: Bool
        let isSeparator: Bool
        let isStop: Bool
        /// UTF-16 offset within the window, and length.
        let offset: Int
        let units: Int
    }

    /// - Parameters:
    ///   - classify: the pair's grapheme classes (`LayoutSnapshot.runClass`).
    ///   - convert: one grapheme typed on `side`'s keys, retyped on the other layout's.
    ///   - direction: P3-37: the side to convert from, decided by the caller (the clipboard convert has no caret: the
    ///     remembered buffer's language). nil = step 3 (the letter nearest the caret).
    static func plan(_ w: FieldWindow, classify: (Character) -> RunCharClass, direction: PairSide? = nil,
                     convert: (PairSide, String) -> String) -> Result {
        let total = w.text.utf16.count
        let caretRel = w.caret - w.location
        guard caretRel >= 0, caretRel <= total else { return .nothing }

        var g: [Grapheme] = []
        var units = 0
        var caretIndex: Int?
        for ch in w.text {
            if caretIndex == nil, units >= caretRel { caretIndex = g.count }
            let cls = classify(ch)
            let n = ch.utf16.count
            let tab = ch == "\t"
            g.append(Grapheme(cls: cls, isLetter: ch.isLetter,
                              isSeparator: cls == .space || cls == .lineBreak || tab,
                              isStop: cls == .hardStop && !tab, offset: units, units: n))
            units += n
        }
        let caret = caretIndex ?? g.count

        // Step 1: the segment holding the caret.
        var lo = 0
        var hi = g.count
        if let stop = g[..<caret].lastIndex(where: \.isStop) { lo = stop + 1 }
        if let stop = g[caret...].firstIndex(where: \.isStop) { hi = stop }
        let hadLetters = g[lo..<hi].contains(where: \.isLetter)

        // Step 2: a word cut by the window's edge is left alone.
        if lo == 0, !w.reachesFieldStart {
            lo = g[lo..<hi].firstIndex(where: \.isSeparator) ?? hi
        }
        let windowEndsAtCaret = w.location + total == w.caret
        if hi == g.count, !w.reachesFieldEnd, !windowEndsAtCaret {
            hi = g[lo..<hi].lastIndex(where: \.isSeparator).map { $0 + 1 } ?? lo
        }
        guard lo < hi else { return hadLetters ? .tooLong : .nothing }

        // Step 3: direction.
        let side: PairSide
        if let direction {
            side = direction   // P3-37
        } else {
            let before = g[lo..<max(lo, min(caret, hi))].last(where: \.isLetter)
            let after = caret < hi ? g[max(caret, lo)..<hi].first(where: \.isLetter) : nil
            guard let nearest = before ?? after, case .strong(let s) = nearest.cls else { return .nothing }
            side = s
        }

        // Steps 4–5: which graphemes convert, word by word.
        var converts = [Bool](repeating: false, count: g.count)
        var i = lo
        while i < hi {
            if g[i].isSeparator { i += 1; continue }
            var j = i
            while j < hi, !g[j].isSeparator { j += 1 }
            mark(i..<j, side: side, g, into: &converts)
            i = j
        }

        // Step 6: the range from the first to the last changed grapheme, and the caret.
        var pieces: [String?] = Array(repeating: nil, count: g.count)
        var first: Int?
        var last: Int?
        let chars = Array(w.text)
        for k in lo..<hi where converts[k] {
            let original = String(chars[k])
            let out = convert(side, original)
            guard !out.isEmpty, !out.unicodeScalars.elementsEqual(original.unicodeScalars) else { continue }
            pieces[k] = out
            if first == nil { first = k }
            last = k
        }
        guard let first, let last else { return .nothing }
        var text = ""
        var caretInNew: Int?
        var written = 0
        for k in first...last {
            if k == caret { caretInNew = written }
            let piece = pieces[k] ?? String(chars[k])
            text += piece
            written += piece.utf16.count
        }
        let offset = g[first].offset
        let end = g[last].offset + g[last].units
        let caretAfter: Int?
        if caretRel <= offset {
            caretAfter = w.caret
        } else if caretRel >= end {
            caretAfter = caretRel == end ? nil : w.caret + (written - (end - offset))
        } else {
            caretAfter = caretInNew.map { w.location + offset + $0 }
        }
        return .convert(Plan(edit: FieldEdit(offset: offset, length: end - offset, caretAfter: caretAfter),
                             text: text, side: side))
    }

    /// Steps 4–5 for one word `r` (no separators inside).
    private static func mark(_ r: Range<Int>, side: PairSide, _ g: [Grapheme], into converts: inout [Bool]) {
        /// The nearest anchor (a letter in the pair or of another script) on each side: true = a letter of `side`.
        func anchor(_ x: Grapheme) -> Bool? {
            guard x.isLetter else { return nil }
            switch x.cls {
            case .strong(let s): return s == side
            case .foreignLetter: return false
            default: return nil   // a letter both layouts type: transparent
            }
        }
        var left: [Bool?] = Array(repeating: nil, count: r.count)
        var seen: Bool?
        for (n, k) in r.enumerated() {
            left[n] = seen
            if let a = anchor(g[k]) { seen = a }
        }
        seen = nil
        for (n, k) in r.enumerated().reversed() {
            let x = g[k]
            let right = seen
            if let a = anchor(x) { seen = a }
            if x.isLetter && x.cls == .strong(side) {
                converts[k] = true
                continue
            }
            let convertible = x.cls == .shared || x.cls == .strong(side)
            guard convertible else { continue }
            let l = left[n]
            converts[k] = (l ?? true) && (right ?? true) && (l != nil || right != nil)
        }
    }
}
