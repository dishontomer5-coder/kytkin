// P2-5: The `kytkin-layoutmap` v1 JSON codec (001 §4.3). Swift would encode `[UInt16: …]` as an array,
// so keys are written as decimal-string object keys. Decoding enforces the per-cell rules and throws
// `LayoutMapError` with the key code and layer; import-only rules live in `LayoutMap.validate`.
// A future `version: 2` gets its own decoder; v1 files keep loading.

import Foundation

extension LayoutMap {
    private enum CodingKeys: String, CodingKey {
        case format, version, id, name, language, source, base, kbdType, keys, deadKeys
    }

    /// Object keys that aren't known up front: key codes, and layer names inside a cell.
    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Format and version first, so a different file type or a v2 file gets the right message.
        let format = try? c.decodeIfPresent(String.self, forKey: .format)
        guard format == LayoutMap.format else { throw LayoutMapError.wrongFormat(format) }
        let version = try? c.decodeIfPresent(Int.self, forKey: .version)
        guard version == LayoutMap.version else { throw LayoutMapError.unsupportedVersion(version) }

        let id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty else { throw LayoutMapError.emptyID }
        self.id = InputSourceID(id)
        name = try c.decode(String.self, forKey: .name)
        language = try c.decode(String.self, forKey: .language)
        let source = try c.decode(String.self, forKey: .source)
        guard let parsed = Source(rawValue: source) else { throw LayoutMapError.invalidSource(source) }
        self.source = parsed
        base = try c.decodeIfPresent(String.self, forKey: .base).map(InputSourceID.init(rawValue:))
        kbdType = try c.decodeIfPresent(Int.self, forKey: .kbdType)

        var keys: [UInt16: KeyCell] = [:]
        let keysContainer = try c.nestedContainer(keyedBy: DynamicKey.self, forKey: .keys)
        for key in keysContainer.allKeys {
            let code = try Self.keyCode(key.stringValue)
            let cellContainer = try keysContainer.nestedContainer(keyedBy: DynamicKey.self, forKey: key)
            var cell = KeyCell()
            for layerKey in cellContainer.allKeys {
                guard let layer = KeyLayer(rawValue: layerKey.stringValue) else {
                    throw LayoutMapError.unknownLayer(keyCode: code, layer: layerKey.stringValue)
                }
                let text = try cellContainer.decode(String.self, forKey: layerKey)
                guard !text.isEmpty else { throw LayoutMapError.emptyString(keyCode: code, layer: layer) }
                guard text.count <= LayoutMap.maxGraphemesPerCell else {
                    throw LayoutMapError.tooManyCharacters(keyCode: code, layer: layer)
                }
                // Typed text only: a control character (newline, tab, backspace, NUL…) would be replayed into
                // the user's app on convert (e.g. a newline runs a command in Terminal). The system provider
                // filters control output too (001 §2.2).
                guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                    throw LayoutMapError.controlCharacter(keyCode: code, layer: layer)
                }
                cell[layer] = text
            }
            keys[code] = cell
        }
        self.keys = keys

        var deadKeys: [UInt16: [KeyLayer]] = [:]
        if c.contains(.deadKeys) {
            let deadContainer = try c.nestedContainer(keyedBy: DynamicKey.self, forKey: .deadKeys)
            for key in deadContainer.allKeys {
                let code = try Self.keyCode(key.stringValue)
                let names = try deadContainer.decode([String].self, forKey: key)
                let layers = try Set(names.map { name in
                    guard let layer = KeyLayer(rawValue: name) else {
                        throw LayoutMapError.unknownLayer(keyCode: code, layer: name)
                    }
                    return layer
                })
                // Canonical form, as `overlaid(on:)` produces it: no duplicates, `allCases` order, no empty lists.
                if !layers.isEmpty { deadKeys[code] = KeyLayer.allCases.filter(layers.contains) }
            }
        }
        self.deadKeys = deadKeys
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(LayoutMap.format, forKey: .format)
        try c.encode(LayoutMap.version, forKey: .version)
        try c.encode(id.rawValue, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(language, forKey: .language)
        try c.encode(source.rawValue, forKey: .source)
        try c.encodeIfPresent(base?.rawValue, forKey: .base)
        try c.encodeIfPresent(kbdType, forKey: .kbdType)
        // KeyCell's synthesized encoding leaves out nil layers.
        let keys = Dictionary(uniqueKeysWithValues: self.keys.map { (String($0.key), $0.value) })
        try c.encode(keys, forKey: .keys)
        if !deadKeys.isEmpty {
            let dead = Dictionary(uniqueKeysWithValues: deadKeys.map { (String($0.key), $0.value.map(\.rawValue)) })
            try c.encode(dead, forKey: .deadKeys)
        }
    }

    /// A canonical decimal key code 0–127 ("7", not "07", "+7" or " 7").
    private static func keyCode(_ string: String) throws -> UInt16 {
        guard let code = UInt16(string), String(code) == string, keyCodeRange.contains(code) else {
            throw LayoutMapError.invalidKeyCode(string)
        }
        return code
    }
}
