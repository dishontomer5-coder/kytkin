// P6-0k (owner 2026-11-18): Settings → Statistics. How many times Kytkin did something for the user, as three counts
// and the date counting began. Counts only: no app names, hosts, words or times of single events.
//
// What counts (`Kind`):
//   converted          a double-Shift that converted text (`ConvertOutcome.converted`; not a language toggle)
//   switchedByApp      an input-source change Kytkin made because of an app rule
//   switchedByWebsite  an input-source change Kytkin made because of a website rule (site or exact subdomain)
// The user's own switches, re-asserts in a fight, the default behaviour and per-chat rules (v1.1) don't count.
//
// Stored in preferences.json under `stats` (`converted`, `switchedByApp`, `switchedByWebsite`, `since`), outside
// `Preferences` so a count never looks like a settings change to the observers of `PreferencesStore.prefs`. Written by
// `PreferencesStore` at most every 30 s (and on quit). A file without `stats` (or with a bad one) starts at zero.

import Foundation

struct UsageStats: Sendable, Equatable, Codable {
    enum Kind: Sendable, Equatable, CaseIterable {
        case converted, switchedByApp, switchedByWebsite
    }

    var converted = 0
    var switchedByApp = 0
    var switchedByWebsite = 0
    /// When counting began (the first count, or the last reset). nil = nothing counted yet.
    var since: Date?

    init(converted: Int = 0, switchedByApp: Int = 0, switchedByWebsite: Int = 0, since: Date? = nil) {
        self.converted = converted
        self.switchedByApp = switchedByApp
        self.switchedByWebsite = switchedByWebsite
        self.since = since
    }

    var total: Int { converted &+ switchedByApp &+ switchedByWebsite }

    func count(_ kind: Kind) -> Int {
        switch kind {
        case .converted: converted
        case .switchedByApp: switchedByApp
        case .switchedByWebsite: switchedByWebsite
        }
    }

    /// One more `kind`; `now` starts the count when nothing was counted yet. Saturates (never wraps).
    mutating func record(_ kind: Kind, now: Date) {
        if since == nil { since = now }
        switch kind {
        case .converted: converted = Self.bump(converted)
        case .switchedByApp: switchedByApp = Self.bump(switchedByApp)
        case .switchedByWebsite: switchedByWebsite = Self.bump(switchedByWebsite)
        }
    }

    private static func bump(_ n: Int) -> Int { n == .max ? n : n + 1 }

    private enum CodingKeys: String, CodingKey { case converted, switchedByApp, switchedByWebsite, since }

    /// Lenient: a missing, mistyped or negative count is 0; a bad date is nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) -> Int { max(0, (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0) }
        converted = count(.converted)
        switchedByApp = count(.switchedByApp)
        switchedByWebsite = count(.switchedByWebsite)
        since = (try? c.decodeIfPresent(Date.self, forKey: .since)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(converted, forKey: .converted)
        try c.encode(switchedByApp, forKey: .switchedByApp)
        try c.encode(switchedByWebsite, forKey: .switchedByWebsite)
        try c.encodeIfPresent(since, forKey: .since)
    }
}
