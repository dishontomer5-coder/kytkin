// P2-7: Converts between two layouts by key position (R6 §6, 001 §2.2). Pure and Sendable; called on @TextActor.
// - `render`: strokes from the word buffer → the text the same keys type in `to` (the double-Shift path).
// - `convert`: text typed in `from` → the text the same keys type in `to` (a selection, no strokes).
// - `guessSource`: which layout of a pair a selection was most likely typed in.
// Text with no key in `from`, or whose key types nothing in `to`, passes through unchanged. Never drops text.

import Foundation

struct LayoutConverter: Sendable {
    let from: LayoutMap
    let to: LayoutMap
    /// `from`'s reverse index. P2-59 (001 §12.3 X1): read-only, so `LayoutSnapshot.runClass` reuses it.
    let sourceIndex: LayoutReverseIndex
    /// `to`'s reverse index, for `guessSource(of:)`. Both are built once per converter (once per pair).
    let targetIndex: LayoutReverseIndex

    init(from: LayoutMap, to: LayoutMap) {
        self.from = from
        self.to = to
        sourceIndex = LayoutReverseIndex(from)
        targetIndex = LayoutReverseIndex(to)
    }

    /// `text` typed on `from`'s keys, retyped on `to`'s. `unmapped` counts the units that passed through
    /// unchanged. Whitespace isn't counted: it types the same everywhere (Space is outside the index).
    func convert(_ text: String) -> (text: String, unmapped: Int) {
        var out = ""
        var unmapped = 0
        Self.forEachUnit(of: text, in: sourceIndex) { unit, stroke in
            if let stroke, let converted = output(for: stroke, typed: unit) {
                out += converted
            } else {
                out += unit
                if !unit.allSatisfy(\.isWhitespace) { unmapped += 1 }
            }
        }
        return (out, unmapped)
    }

    /// The text `strokes` type in `to`. A key that types nothing in `to` keeps what it typed in `from`;
    /// a key that types nothing in either adds nothing.
    func render(_ strokes: [Stroke]) -> String {
        var out = ""
        for stroke in strokes {
            let typed = from.keys[stroke.keyCode]?[stroke.layer]
            out += output(for: stroke, typed: typed) ?? typed ?? ""
        }
        return out
    }

    /// P2-7: the layout of `pair` whose reverse index covers more of `text` (001 flow (c) step 4).
    /// `nil` on a tie, including text neither layout types (digits, punctuation both share, empty text).
    /// Builds both indexes on every call; a caller that keeps a converter per pair should use the instance method.
    static func guessSource(of text: String, among pair: (LayoutMap, LayoutMap)) -> InputSourceID? {
        LayoutConverter(from: pair.0, to: pair.1).guessSource(of: text)
    }

    /// P2-7: `guessSource` between `from` and `to`, reusing the indexes built in `init`.
    func guessSource(of text: String) -> InputSourceID? {
        let first = Self.coverage(of: text, in: sourceIndex)
        let second = Self.coverage(of: text, in: targetIndex)
        if first == second { return nil }
        return first > second ? from.id : to.id
    }

    // MARK: - Private

    /// What `stroke` types in `to`, given that it typed `typed` in `from`. `nil` = `to` types nothing there.
    ///
    /// P2-7 case rule (R6 §6 ambiguity 3, refined by the Coordinator): Hebrew has no case, and Apple Hebrew's
    /// Shift+letter is empty or a pointed letter (Shift+a = שׁ). So for a Shift (or Caps Lock) letter whose
    /// key types a caseless letter unshifted in `to`:
    /// - if the key's Shift output in `to` is one bare caseless letter (no marks), use it: phonetic layouts put
    ///   distinct letters there (Hebrew-QWERTY Shift+s = ש, so ABC `S` → ש);
    /// - else use the plain letter: `Akuo` → `שלום`, not `שׁלום` (Apple Hebrew), and not `Aלום` (Hebrew-PC).
    /// An empty string in `to` counts as "types nothing", so the caller passes the original through.
    private func output(for stroke: Stroke, typed: String?) -> String? {
        let cell = to.keys[stroke.keyCode]
        if stroke.layer == .shift || stroke.layer == .capsLock,
           let typed, Self.isLetters(typed),
           let plain = cell?.plain, Self.isCaselessLetters(plain) {
            if let shifted = cell?.shift, Self.isBareCaselessLetter(shifted) { return shifted }
            return plain
        }
        guard let text = cell?[stroke.layer], !text.isEmpty else { return nil }
        return text
    }

    /// R6 §6: a unit is the whole grapheme if some key types it (e.g. "לֹ"), else each Unicode scalar on its
    /// own, so a letter with niqqud the layout can't type still converts its base letter and keeps the marks.
    private static func forEachUnit(of text: String, in index: LayoutReverseIndex,
                                    _ body: (String, Stroke?) -> Void) {
        for character in text {
            let grapheme = String(character)
            if let stroke = index.stroke(for: grapheme) {
                body(grapheme, stroke)
                continue
            }
            for scalar in character.unicodeScalars {
                let unit = String(scalar)
                body(unit, index.stroke(for: unit))
            }
        }
    }

    private static func coverage(of text: String, in index: LayoutReverseIndex) -> Int {
        var count = 0
        forEachUnit(of: text, in: index) { _, stroke in if stroke != nil { count += 1 } }
        return count
    }

    private static func isLetters(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isLetter) }

    private static func isCaselessLetters(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter && !$0.isCased }
    }

    /// One Unicode scalar that is a caseless letter (general category Lo or Lm): `ש` yes; `שׁ` (has a mark),
    /// a lone qamats (Hebrew points are `Alphabetic`, so `Character.isLetter` says yes), `A`, `„` no.
    private static func isBareCaselessLetter(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        guard scalars.count == 1, let category = scalars.first?.properties.generalCategory else { return false }
        return category == .otherLetter || category == .modifierLetter
    }
}
