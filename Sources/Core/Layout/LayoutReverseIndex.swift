// P2-7: "Which key types this text?" for one LayoutMap (R6 §6, 001 §2.2).
// Built from the plain and shift layers only. Caps Lock is left out because Apple Hebrew's Caps Lock layer
// types Latin letters, which would "convert" English inside Hebrew text (R6 §6 ambiguity 2). Option layers
// are left out because niqqud, typographic quotes and LRM/RLM are noise for wrong-layout fixes (ambiguity 4).

import Foundation

struct LayoutReverseIndex: Sendable {
    /// Space (49) types the same in every layout, so it stays out of the index (R6 §2).
    static let excludedKeyCodes: Set<UInt16> = [49]
    static let layers: [KeyLayer] = [.plain, .shift]

    private let strokes: [String: Stroke]

    init(_ map: LayoutMap) {
        var best: [String: (rank: Rank, stroke: Stroke)] = [:]
        for (code, cell) in map.keys where !Self.excludedKeyCodes.contains(code) {
            for (layerRank, layer) in Self.layers.enumerated() {
                guard let text = cell[layer] else { continue }
                let rank = Rank(key: Self.keyRank(code), layer: layerRank, keyCode: code)
                if let current = best[text], current.rank <= rank { continue }
                best[text] = (rank, Stroke(keyCode: code, layer: layer))
            }
        }
        strokes = best.mapValues(\.stroke)
    }

    /// The stroke that types `text`, or `nil` if no plain/shift key types it.
    func stroke(for text: String) -> Stroke? { strokes[text] }

    // MARK: - Ranking

    /// P2-7: when several strokes type the same text, the lowest (key rank, layer, key code) wins, so the
    /// answer is deterministic: a `1` maps to main-row key 18, not keypad 83 (R6 §2, §6 ambiguity 1).
    private struct Rank: Comparable {
        let key: Int
        let layer: Int
        let keyCode: UInt16

        static func < (a: Rank, b: Rank) -> Bool {
            (a.key, a.layer, a.keyCode) < (b.key, b.layer, b.keyCode)
        }
    }

    /// Main keys < keypad keys (65–92) < JIS-only keys (93, 94, 95, 102, 104).
    static func keyRank(_ code: UInt16) -> Int {
        switch code {
        case 93, 94, 95, 102, 104: 2
        case 65...92: 1
        default: 0
        }
    }
}
