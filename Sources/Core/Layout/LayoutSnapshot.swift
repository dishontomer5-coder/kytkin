// P2-21: An immutable, Sendable copy of the active pair's two layouts (001 §2.2 Controllers), built on main from
// the LayoutMapProvider and handed to `@TextActor` with each convert. It keeps one LayoutConverter per direction,
// so the reverse indexes are built once per pair, not once per convert (001 §2.2: "use the instance guessSource").
//
// Every answer is in the pair's InputSourceIDs (an imported map may carry another id). Pure; holds no typed text.

import Foundation

struct LayoutSnapshot: Sendable {
    let pair: LanguagePair
    /// pair.a → pair.b
    private let aToB: LayoutConverter
    /// pair.b → pair.a
    private let bToA: LayoutConverter

    /// nil when the two maps are the same layout (nothing to convert between).
    init?(pair: LanguagePair, a: LayoutMap, b: LayoutMap) {
        guard pair.a != pair.b else { return nil }
        self.pair = pair
        aToB = LayoutConverter(from: a, to: b)
        bToA = LayoutConverter(from: b, to: a)
    }

    /// The converter that reads `source`'s keys and writes the other layout's. nil if `source` isn't in the pair.
    func converter(from source: InputSourceID) -> LayoutConverter? {
        if source == pair.a { return aToB }
        if source == pair.b { return bToA }
        return nil
    }

    /// What `strokes` typed in `source` (the text on screen now). nil if `source` isn't in the pair, or if any
    /// stroke is a dead key or types nothing there: the on-screen text is then unknown, and the caller must not
    /// count backspaces from it.
    func typed(_ strokes: [Stroke], in source: InputSourceID) -> String? {
        guard let map = converter(from: source)?.from else { return nil }
        var out = ""
        var graphemes = 0
        for s in strokes {
            // A dead key types nothing by itself (it changes the next key), so the screen can't be counted.
            if map.deadKeys[s.keyCode]?.contains(s.layer) == true { return nil }
            guard let text = map.keys[s.keyCode]?[s.layer], !text.isEmpty else { return nil }
            out += text
            graphemes += text.count
        }
        // P2-21 QA: a stroke whose text joined the previous grapheme (a niqqud or other combining mark from the
        // Option layer) makes the Backspace count app-dependent: browsers delete one code point, Cocoa a cluster.
        // Unknown → the caller takes the AX path, which selects the exact range.
        return out.count == graphemes ? out : nil
    }

    /// The same keys rendered in the other layout of the pair (the double-Shift last-word path, 001 §3 (c) step 4).
    func render(_ strokes: [Stroke], from source: InputSourceID) -> (target: InputSourceID, text: String)? {
        guard let c = converter(from: source), let target = pair.other(than: source) else { return nil }
        return (target, c.render(strokes))
    }

    /// The pair layout `text` was most likely typed in (instance `guessSource`, mapped to the pair's ids).
    /// nil on a tie (digits, shared punctuation, empty text).
    func guessSource(of text: String) -> InputSourceID? {
        guard let guess = aToB.guessSource(of: text) else { return nil }
        return guess == aToB.from.id ? pair.a : pair.b
    }

    /// A selection (or an AX-read word): guess its layout, then retype it on the other one. nil when the layout
    /// can't be told or the text wouldn't change, so nothing is written for nothing.
    func convertGuessing(_ text: String) -> (source: InputSourceID, target: InputSourceID, text: String)? {
        guard let source = guessSource(of: text), let c = converter(from: source),
              let target = pair.other(than: source) else { return nil }
        let out = c.convert(text).text
        guard !out.isEmpty, out != text else { return nil }
        return (source, target, out)
    }
}
