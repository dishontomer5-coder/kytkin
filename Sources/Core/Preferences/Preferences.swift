// P2-8: The whole preferences.json, schema v1 (001 §4.2). Every field has a default, so `{}` decodes
// to `Preferences()`. Decoding is lenient field by field (LenientDecoding.swift); `rules` drops only
// a bad entry, and hosts/domains are trimmed of whitespace on load. `schemaVersion` is not a field:
// PreferencesCodec reads it, migrates, and writes it.
// Not stored here, on purpose: launch at login (read from SMAppService), capability verdicts, and
// anything typed, titled or URL-shaped (design.md privacy invariants).

import Foundation

struct Preferences: Sendable, Equatable {
    /// The schema this build reads and writes.
    static let currentSchemaVersion = 1

    var languagePair: LanguagePair = .default
    var general = General()
    var convert = Convert()
    var autoFix = AutoFix()
    var browsers = Browsers()
    var rules: [Rule] = []
    /// Only apps the user changed, keyed by bundle ID. Shipped defaults live in code (001 §4.2 notes).
    var apps: [String: AppOverride] = [:]
    /// Phase 4 slot (HMAC'd undo exceptions). P2-8 only carries it through load and save.
    var autoFixExceptions = AutoFixExceptions()

    init() {}
}

extension Preferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case languagePair, general, convert, autoFix, browsers, rules, apps, autoFixExceptions
    }

    init(from decoder: Decoder) throws {
        // Throws only if the top level isn't a JSON object.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(LanguagePair.self, .languagePair) { languagePair = v }
        if let v = c.lenient(General.self, .general) { general = v }
        if let v = c.lenient(Convert.self, .convert) { convert = v }
        if let v = c.lenient(AutoFix.self, .autoFix) { autoFix = v }
        if let v = c.lenient(Browsers.self, .browsers) { browsers = v }
        if let v = c.lenient([Lossy<Rule>].self, .rules) {
            rules = v.compactMap(\.value).map(Self.trimmed)
        }
        if let v = c.lenient([String: Lossy<AppOverride>].self, .apps) {
            var apps: [String: AppOverride] = [:]
            // Sorted, so which of two IDs that trim to the same one wins doesn't depend on hash order.
            for (bundleID, entry) in v.sorted(by: { $0.key < $1.key }) {
                let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, let value = entry.value, apps[id] == nil else {
                    // A bad entry was already recorded by Lossy; record a blank or duplicate ID here.
                    if entry.value != nil { PreferencesDecodingLoss.record() }
                    continue
                }
                apps[id] = value
            }
            self.apps = apps
        }
        if let v = c.lenient(AutoFixExceptions.self, .autoFixExceptions) { autoFixExceptions = v }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(languagePair, forKey: .languagePair)
        try c.encode(general, forKey: .general)
        try c.encode(convert, forKey: .convert)
        try c.encode(autoFix, forKey: .autoFix)
        try c.encode(browsers, forKey: .browsers)
        try c.encode(rules, forKey: .rules)
        try c.encode(apps, forKey: .apps)
        try c.encode(autoFixExceptions, forKey: .autoFixExceptions)
    }

    /// P2-8: hand-edited files may hold " ynet.co.il " (P2-9 note). Case and a trailing dot are
    /// left alone: RuleEngine already ignores them.
    private static func trimmed(_ rule: Rule) -> Rule {
        var r = rule
        switch r.scope {
        case .site(let domain):
            r.scope = .site(domain: domain.trimmingCharacters(in: .whitespacesAndNewlines))
        case .siteHost(let host):
            r.scope = .siteHost(host: host.trimmingCharacters(in: .whitespacesAndNewlines))
        case .app, .chat:
            break
        }
        return r
    }
}
