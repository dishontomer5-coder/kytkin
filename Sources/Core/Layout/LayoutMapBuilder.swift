// P2-6: Builds a system LayoutMap from a per-cell translate function (001 §2.2, R6 §2).
// The System adapter supplies UCKeyTranslate; this pure part decides what goes in the map, so the
// filtering rules are unit-tested without TIS.

import Foundation

enum LayoutMapBuilder {
    /// What one (key code, layer) cell types.
    enum Translation: Sendable, Equatable {
        case text(String)
        /// A dead key, with its standalone form (e.g. ABC Option+e → "´").
        case dead(String)
    }

    /// Calls `translate` for every key code 0–127 × layer and keeps only typed text (see `typedText`).
    /// A dead cell whose standalone form is filtered out is left out, and isn't marked dead.
    static func build(id: InputSourceID, name: String, language: String, kbdType: Int?,
                      translate: (UInt16, KeyLayer) -> Translation?) -> LayoutMap {
        var keys: [UInt16: KeyCell] = [:]
        var deadKeys: [UInt16: [KeyLayer]] = [:]
        for code in LayoutMap.keyCodeRange {
            var cell = KeyCell()
            var dead: [KeyLayer] = []
            for layer in KeyLayer.allCases {
                let raw: String, isDead: Bool
                switch translate(code, layer) {
                case .text(let t)?: (raw, isDead) = (t, false)
                case .dead(let t)?: (raw, isDead) = (t, true)
                case nil: continue
                }
                guard let text = typedText(raw) else { continue }
                cell[layer] = text
                if isDead { dead.append(layer) }
            }
            if !cell.definedLayers.isEmpty { keys[code] = cell }
            if !dead.isEmpty { deadKeys[code] = dead }
        }
        return LayoutMap(id: id, name: name, language: language, source: .system,
                         kbdType: kbdType, keys: keys, deadKeys: deadKeys)
    }

    /// P2-6: `text` if a key may "type" it, else `nil`. Drops what isn't text (R6 §2): empty output, any
    /// control character (Return, Tab, Esc, arrows' U+001C–1F, Delete U+007F, keypad Enter U+0003…),
    /// private-use function-key codes (U+F700–F8FF), line/paragraph separators, and anything over the
    /// codec's grapheme or scalar limit. Invisible format characters (LRM/RLM) and NBSP are real text and are kept.
    /// P2-30: the same predicate the importer uses (`LayoutMap.cellViolation`), so a generated map always
    /// passes the decoder and `jsonData()`.
    static func typedText(_ text: String) -> String? {
        LayoutMap.cellViolation(text) == nil ? text : nil
    }
}
