// P2-8: The schema-v1 slot for auto-fix exceptions (001 §4.2). Phase 4 owns the semantics: the
// HMAC key in the Keychain, hashing, LRU eviction. P2-8 only round-trips what is stored.
// `h` is base64 HMAC-SHA256, never a word (design.md privacy invariants). `lastUsed` is a day, "yyyy-MM-dd".

import Foundation

extension Preferences {
    struct AutoFixExceptions: Sendable, Equatable {
        struct Entry: Codable, Sendable, Equatable {
            var h: String
            var lastUsed: String

            init(h: String, lastUsed: String) {
                self.h = h
                self.lastUsed = lastUsed
            }
        }

        static let defaultCap = 2_000

        var algorithm = "HMAC-SHA256"
        var cap = AutoFixExceptions.defaultCap
        var entries: [Entry] = []

        init() {}
    }
}

extension Preferences.AutoFixExceptions: Codable {
    private enum CodingKeys: String, CodingKey { case algorithm, cap, entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(String.self, .algorithm) { algorithm = v }
        if let v = c.lenient(Int.self, .cap) {
            if v > 0 { cap = v } else { PreferencesDecodingLoss.record() }
        }
        if let v = c.lenient([Lossy<Entry>].self, .entries) { entries = v.compactMap(\.value) }
    }
}
