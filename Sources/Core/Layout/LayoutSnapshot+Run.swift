// P2-59: The run convert's layout answers (001 §12.3 X1, X5). Pure; holds no typed text.
//   - `runClass(of:)`: one grapheme's class from the pair's two reverse indexes (the ones `guessSource` uses).
//   - `typedRun` / `renderRun`: the whole word buffer, words joined by their spaces, as typed now and as the same
//     keys type in the other layout (the key path in apps whose text can't be read).

import Foundation

extension LayoutSnapshot {
    /// The pair's input source for `side`.
    func source(of side: PairSide) -> InputSourceID { side == .a ? pair.a : pair.b }

    /// The side `source` is on, or nil if it isn't in the pair.
    func side(of source: InputSourceID) -> PairSide? {
        if source == pair.a { return .a }
        if source == pair.b { return .b }
        return nil
    }

    /// X1: a grapheme is looked up whole; if neither index has it, it is classed by its first scalar (so a Hebrew
    /// letter with niqqud is strong B, as `LayoutConverter.forEachUnit` treats it).
    func runClass(of character: Character) -> RunCharClass {
        let grapheme = String(character)
        // P3-33: line breaks are crossed (the whole run, any number of lines); other control characters still stop it.
        if character.unicodeScalars.allSatisfy(ReplacementPlanner.isLineBreak) { return .lineBreak }
        if ReplacementPlanner.containsUnsafeCharacter(grapheme) { return .hardStop }
        if character.isWhitespace { return .space }
        let a = converter(from: pair.a)?.sourceIndex
        let b = converter(from: pair.a)?.targetIndex
        var inA = a?.stroke(for: grapheme) != nil
        var inB = b?.stroke(for: grapheme) != nil
        if !inA && !inB, let first = character.unicodeScalars.first {
            let scalar = String(first)
            inA = a?.stroke(for: scalar) != nil
            inB = b?.stroke(for: scalar) != nil
        }
        switch (inA, inB) {
        case (true, true): return .shared
        case (true, false): return .strong(.a)
        case (false, true): return .strong(.b)
        case (false, false): return character.isLetter ? .foreignLetter : .foreignOther
        }
    }

    /// X5: the buffer's text on screen now: `w0 + " "×g0 + w1 + … + current`, typed in `source`. nil when there is
    /// no run, `source` isn't in the pair, any word's `typed` is nil (dead key, a mark joining the letter before),
    /// the text holds a control character, or it has more scalars than graphemes (a combining mark: Backspace
    /// counts differ between apps, P2-49 item 1, X4), so the caller never counts backspaces from it.
    func typedRun(_ run: some BufferedRun, in source: InputSourceID) -> String? {
        guard run.gaps.count == run.previousWords.count, run.gaps.allSatisfy({ $0 >= 0 }),
              !run.strokes.isEmpty || !run.previousWords.isEmpty else { return nil }
        var out = ""
        var graphemes = 0
        for (word, gap) in zip(run.previousWords, run.gaps) {
            guard let text = typed(word, in: source) else { return nil }
            out += text + String(repeating: " ", count: gap)
            graphemes += text.count + gap
        }
        guard let current = typed(run.strokes, in: source) else { return nil }
        out += current
        graphemes += current.count
        guard !out.isEmpty, out.count == graphemes, out.unicodeScalars.count == graphemes,
              !ReplacementPlanner.containsUnsafeCharacter(out) else { return nil }
        return out
    }

    /// X5: the same keys rendered in the other layout of the pair, with the same spaces. nil whenever `typedRun`
    /// is nil (what is on screen is then unknown, so nothing may be retyped over it).
    func renderRun(_ run: some BufferedRun, from source: InputSourceID) -> (target: InputSourceID, text: String)? {
        guard typedRun(run, in: source) != nil, let c = converter(from: source),
              let target = pair.other(than: source) else { return nil }
        var out = ""
        for (word, gap) in zip(run.previousWords, run.gaps) {
            out += c.render(word) + String(repeating: " ", count: gap)
        }
        out += c.render(run.strokes)
        return (target, out)
    }

    /// P3-37 / P3-62: ⌘ + the ANSI C / V keys is ⌘C / ⌘V for this pair: one of its layouts types plain `c` and `v` on
    /// exactly those key codes (ABC, U.S., British, AZERTY…; Apple Hebrew's Command layer is QWERTY). On Dvorak C is
    /// `j`, so the clipboard convert is never used there. (⇧⌘↑ is an arrow key: the same in every layout.)
    ///
    /// P3-37 QA: macOS reads ⌘ + key in the layout **in front**, so one Latin layout of the pair typing c/v is not
    /// enough: with ABC ⇄ Dvorak and Dvorak in front, ⌘ + the C key is ⌘J. Every layout of the pair that types Latin
    /// letters on those keys must type exactly c, v; a non-Latin one (Hebrew, Russian, Greek: their Command layer is
    /// QWERTY) is allowed, and at least one layout must type c/v. (A non-Latin layout with a non-QWERTY Command layer
    /// can't be told apart from its plain keys: a known gap.)
    var clipboardShortcutsAreSafe: Bool {
        guard let a = converter(from: pair.a)?.from, let b = converter(from: pair.b)?.from else { return false }
        enum Kind { case acv, nonLatin, unsafe }
        func kind(_ map: LayoutMap) -> Kind {
            let cells = ClipboardShortcut.allCases.map { (map.keys[$0.keyCode]?.plain, $0.letter) }
            if cells.allSatisfy({ $0.0 == $0.1 }) { return .acv }
            let latin = cells.contains { cell in
                cell.0?.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic } ?? false
            }
            return latin ? .unsafe : .nonLatin
        }
        let kinds = [kind(a), kind(b)]
        return !kinds.contains(.unsafe) && kinds.contains(.acv)
    }
}
