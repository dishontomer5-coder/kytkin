// P2-8: preferences.json ⇄ Preferences (001 §2.2, §4.1). Pure: no file access.
//
// Decode:
//   1. The data must be a JSON object, and `schemaVersion` (if present) a positive integer.
//      Anything else throws `DecodeError`, and PreferencesStore quarantines the file.
//      A missing `schemaVersion` counts as the current version, so `{}` decodes to the defaults.
//   2. Older versions run through PreferencesMigrator on the raw object (`migratedFrom` is set).
//   3. A newer version is decoded as far as v1 understands it (`newerSchemaVersion` is set); the
//      store then never writes the file (read-only, 001 §4.1).
//   4. Fields decode leniently (Preferences.swift). Dates are ISO 8601, with or without fractional seconds.
//      If leniency dropped or defaulted a stored value, `isLossy` is set; the store then keeps a copy of
//      the original file before its first save (`preferences.lossy-<ISO date>.bak.json`).
// Encode: pretty-printed, sorted keys (stable bytes), ISO 8601 dates in whole seconds, plus `schemaVersion`.

import Foundation

enum PreferencesCodec {
    enum DecodeError: Error, Equatable {
        case notJSON
        case notAnObject
        case badSchemaVersion
        case migrationFailed(from: Int)
    }

    /// Everything the store needs to know about a decoded file.
    struct Decoded: Sendable, Equatable {
        let prefs: Preferences
        /// The file's version when it was older and got migrated.
        let migratedFrom: Int?
        /// The file's version when it is newer than this build knows (open read-only).
        let newerSchemaVersion: Int?
        /// Lenient decoding threw something stored away: a bad entry, a mistyped or unknown-valued
        /// field, a non-array `rules`, a clamped number. Unknown keys and missing fields don't count.
        let isLossy: Bool
    }

    /// The 001 §2.2 contract. Use `decodeDetailed` to also learn about a newer schema.
    static func decode(_ d: Data) throws -> (Preferences, migratedFrom: Int?) {
        let r = try decodeDetailed(d)
        return (r.prefs, r.migratedFrom)
    }

    static func decodeDetailed(_ d: Data, migrator: PreferencesMigrator = .standard) throws -> Decoded {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        } catch {
            throw DecodeError.notJSON
        }
        guard let object = raw as? [String: Any] else { throw DecodeError.notAnObject }

        // JSONDecoder is stricter than JSONSerialization here: it rejects `true`, `1.5` and `"1"` for an Int.
        struct Header: Decodable { let schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: d) else { throw DecodeError.badSchemaVersion }
        let version = header.schemaVersion ?? migrator.currentVersion
        guard version >= 1 else { throw DecodeError.badSchemaVersion }

        var body = d
        var migratedFrom: Int?
        var newer: Int?
        if version < migrator.currentVersion {
            let migrated: PreferencesMigrator.JSONObject
            do {
                migrated = try migrator.migrate(object, from: version)
            } catch {
                throw DecodeError.migrationFailed(from: version)
            }
            guard JSONSerialization.isValidJSONObject(migrated),
                  let data = try? JSONSerialization.data(withJSONObject: migrated, options: []) else {
                throw DecodeError.migrationFailed(from: version)
            }
            body = data
            migratedFrom = version
        } else if version > migrator.currentVersion {
            newer = version
        }

        do {
            let recorder = PreferencesDecodingLoss.Recorder()
            let prefs = try PreferencesDecodingLoss.$current.withValue(recorder) {
                try makeDecoder().decode(Preferences.self, from: body)
            }
            return Decoded(prefs: prefs, migratedFrom: migratedFrom, newerSchemaVersion: newer,
                           isLossy: recorder.count > 0)
        } catch {
            throw DecodeError.notAnObject
        }
    }

    static func encode(_ p: Preferences, schemaVersion: Int = Preferences.currentSchemaVersion) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601))
        }
        return try e.encode(Envelope(schemaVersion: schemaVersion, prefs: p))
    }

    // MARK: - Private

    /// Writes `schemaVersion` into the same JSON object as the Preferences fields.
    private struct Envelope: Encodable {
        let schemaVersion: Int
        let prefs: Preferences

        private enum CodingKeys: String, CodingKey { case schemaVersion }

        func encode(to encoder: Encoder) throws {
            try prefs.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? Date(s, strategy: .iso8601) { return date }
            if let date = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected an ISO 8601 date")
        }
        return d
    }
}
