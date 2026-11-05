// P2-30: The one set of rules for what a LayoutMap cell may contain (001 §4.3, hardening plan items 3 and 5).
// The JSON decoder (import), `jsonData()` (export) and `LayoutMapBuilder` (system maps) all call
// `cellViolation`, so a generated map, an exported file and an imported file agree on what "typeable" means.

import Foundation

extension LayoutMap {
    /// P2-30: one "grapheme" can carry a long combining run, so scalars are capped too (on top of 4 graphemes).
    static let maxScalarsPerCell = 16

    /// Why a cell's text can't be typed by a key. `nil` from `cellViolation` = the text is fine.
    enum CellViolation: Sendable, Equatable {
        case empty
        case tooManyGraphemes
        case tooManyScalars
        /// Cc: newline, tab, Return, Escape, Backspace, NUL, DEL…
        case control
        /// Co (private use, e.g. the U+F700 function-key range that apps read as arrow keys) or
        /// Zl/Zp (U+2028 line / U+2029 paragraph separator), which act as line breaks.
        case untypeable
    }

    /// P2-30: the shared "typeable text" predicate for one scalar. Rejects Cc, Co, Zl and Zp.
    /// Everything else is kept, including the invisible format marks LRM/RLM (Cf, typed by Apple's Hebrew
    /// layouts on Option) and NBSP (Zs, Option+Space on ABC): they are real text.
    static func isTypeable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .privateUse, .lineSeparator, .paragraphSeparator: false
        default: true
        }
    }

    /// P2-30: the full rule for one cell: non-empty, ≤ 4 grapheme clusters, ≤ 16 Unicode scalars,
    /// and every scalar typeable. A Cc scalar is reported as `.control` even if other bad scalars are present,
    /// so the existing `controlCharacter` error keeps its meaning.
    static func cellViolation(_ text: String) -> CellViolation? {
        if text.isEmpty { return .empty }
        if text.count > maxGraphemesPerCell { return .tooManyGraphemes }
        let scalars = text.unicodeScalars
        if scalars.count > maxScalarsPerCell { return .tooManyScalars }
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return .control }
        if !scalars.allSatisfy(isTypeable) { return .untypeable }
        return nil
    }

    /// P2-30: throws the `LayoutMapError` for a bad cell, naming its key and layer.
    static func checkCell(_ text: String, keyCode: UInt16, layer: KeyLayer) throws {
        switch cellViolation(text) {
        case nil: return
        case .empty: throw LayoutMapError.emptyString(keyCode: keyCode, layer: layer)
        case .tooManyGraphemes: throw LayoutMapError.tooManyCharacters(keyCode: keyCode, layer: layer)
        case .tooManyScalars: throw LayoutMapError.tooManyScalars(keyCode: keyCode, layer: layer)
        case .control: throw LayoutMapError.controlCharacter(keyCode: keyCode, layer: layer)
        case .untypeable: throw LayoutMapError.untypeableCharacter(keyCode: keyCode, layer: layer)
        }
    }
}
