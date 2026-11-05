// P2-5: A keyboard layout as data: key code (0–127) × layer → the text it types (001 §2.2, design.md).
// Built from the system (P2-6), imported as JSON, or a user's override cells on top of a `base`.
// The JSON codec (`kytkin-layoutmap` v1, 001 §4.3) is in LayoutMap+Codable.swift.

import Foundation

struct LayoutMap: Codable, Sendable, Equatable {
    var id: InputSourceID
    var name: String
    var language: String
    var source: Source
    var base: InputSourceID?
    var kbdType: Int?
    var keys: [UInt16: KeyCell]
    /// Cells whose text in `keys` is the standalone form of a dead key (e.g. ABC Option+e → "´").
    var deadKeys: [UInt16: [KeyLayer]]

    enum Source: String, Codable, Sendable {
        case system, imported, user
    }

    static let format = "kytkin-layoutmap"
    static let version = 1
    static let keyCodeRange: ClosedRange<UInt16> = 0...127
    static let maxFileBytes = 256 * 1024
    static let maxGraphemesPerCell = 4
    static let reservedIDPrefix = "com.apple."
    static let userIDPrefix = "user."

    init(id: InputSourceID, name: String, language: String, source: Source,
         base: InputSourceID? = nil, kbdType: Int? = nil,
         keys: [UInt16: KeyCell] = [:], deadKeys: [UInt16: [KeyLayer]] = [:]) {
        self.id = id
        self.name = name
        self.language = language
        self.source = source
        self.base = base
        self.kbdType = kbdType
        self.keys = keys
        self.deadKeys = deadKeys
    }

    /// P2-5: user tweaks = `base` + this map's cells. Merges per layer: a layer this map defines replaces
    /// the base's text (and the base's dead-key mark) for that key and layer; every other layer keeps the
    /// base's value. Identity (id, name, language, source, base) comes from `self`; `kbdType` from
    /// `self` if set, else from the base. The caller picks the right base (normally `self.base`).
    func overlaid(on base: LayoutMap) -> LayoutMap {
        var keys = base.keys
        var dead = base.deadKeys.mapValues { Set($0) }
        for (code, cell) in self.keys {
            var merged = keys[code] ?? KeyCell()
            for layer in cell.definedLayers {
                merged[layer] = cell[layer]
                dead[code]?.remove(layer)
            }
            keys[code] = merged
        }
        for (code, layers) in deadKeys {
            dead[code, default: []].formUnion(layers)
        }
        let deadKeys = dead.compactMapValues { layers -> [KeyLayer]? in
            let ordered = KeyLayer.allCases.filter(layers.contains)
            return ordered.isEmpty ? nil : ordered
        }
        return LayoutMap(id: id, name: name, language: language, source: source,
                         base: self.base ?? base.id, kbdType: kbdType ?? base.kbdType,
                         keys: keys, deadKeys: deadKeys)
    }

    /// P2-30: imported ids become file names in `layouts/` (001 §4.3), so they are limited to this set.
    static let maxIDLength = 64

    /// P2-30: `[A-Za-z0-9._-]`, ASCII only (`Character.isLetter` would allow any script).
    static func isAllowedIDScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: true   // A–Z, a–z, 0–9
        case 0x2E, 0x5F, 0x2D: true                        // . _ -
        default: false
        }
    }

    /// P2-5: import validation (001 §4.3). Everything the decoder checks (format, version, required
    /// fields, key codes 0–127, known layer names, and the shared cell rules in LayoutMap+CellRules.swift)
    /// plus the import-only rules: file ≤ 256 KB, the ID isn't `com.apple.…` (it gets a `user.` prefix
    /// if it lacks one), and a `user` map has a non-empty `base`.
    /// P2-30: also `source: "system"` is rejected (system maps are export only), and the final id (after
    /// the `user.` prefix) is only `[A-Za-z0-9._-]`, at most 64 characters, and not just `user.`.
    static func validate(_ data: Data) throws -> LayoutMap {
        guard data.count <= maxFileBytes else { throw LayoutMapError.fileTooLarge(bytes: data.count) }
        var map: LayoutMap
        do {
            map = try JSONDecoder().decode(LayoutMap.self, from: data)
        } catch let error as LayoutMapError {
            throw error
        } catch let error as DecodingError {
            throw LayoutMapError(error)
        }
        let raw = map.id.rawValue
        if raw.hasPrefix(reservedIDPrefix) { throw LayoutMapError.reservedID(raw) }
        // P2-30: after the reserved-id check, so a re-imported Apple export still says "reserved for Apple".
        if map.source == .system { throw LayoutMapError.systemSourceImport }
        if !raw.hasPrefix(userIDPrefix) { map.id = InputSourceID(userIDPrefix + raw) }
        try checkImportableID(map.id.rawValue)
        if map.source == .user, map.base?.rawValue.isEmpty ?? true { throw LayoutMapError.missingBase }
        return map
    }

    /// P2-30: the id rules for an id that already has its `user.` prefix.
    private static func checkImportableID(_ id: String) throws {
        guard id.unicodeScalars.allSatisfy(isAllowedIDScalar) else { throw LayoutMapError.invalidIDCharacters(id) }
        guard id.count <= maxIDLength else { throw LayoutMapError.idTooLong(length: id.count) }
        guard id != userIDPrefix else { throw LayoutMapError.idOnlyPrefix }
    }

    /// P2-5: export as `kytkin-layoutmap` v1. Sorted keys and pretty-printed, so files diff cleanly.
    /// P2-30: throws instead of writing a file that wouldn't load back (see `checkEncodable`).
    func jsonData() throws -> Data {
        try checkEncodable()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxFileBytes else { throw LayoutMapError.fileTooLarge(bytes: data.count) }
        return data
    }

    /// P2-30: the rules a map must meet before it is written. Every map: a non-empty id, key codes 0–127
    /// (in `keys` and `deadKeys`), and the shared cell rules. An `imported` or `user` map must also pass
    /// `validate`'s import rules, so its export imports again. A `system` map keeps its `com.apple.` (or
    /// third-party) id: it is export only, and `validate` rejects it by design.
    func checkEncodable() throws {
        guard !id.rawValue.isEmpty else { throw LayoutMapError.emptyID }
        for (code, cell) in keys {
            guard Self.keyCodeRange.contains(code) else { throw LayoutMapError.invalidKeyCode(String(code)) }
            for layer in KeyLayer.allCases {
                guard let text = cell[layer] else { continue }
                try Self.checkCell(text, keyCode: code, layer: layer)
            }
        }
        for code in deadKeys.keys where !Self.keyCodeRange.contains(code) {
            throw LayoutMapError.invalidKeyCode(String(code))
        }
        guard source != .system else { return }
        let raw = id.rawValue
        if raw.hasPrefix(Self.reservedIDPrefix) { throw LayoutMapError.reservedID(raw) }
        try Self.checkImportableID(raw.hasPrefix(Self.userIDPrefix) ? raw : Self.userIDPrefix + raw)
        if source == .user, base?.rawValue.isEmpty ?? true { throw LayoutMapError.missingBase }
    }
}
