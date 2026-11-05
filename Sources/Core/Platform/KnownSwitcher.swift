// P2-13: One other input-source switcher Kytkin warns about (001 §2.2 KnownSwitchers, R1 "Risks", P1-12).

import Foundation

struct KnownSwitcher: Sendable, Equatable {
    /// Display name for the warning ("FlicKey is also switching layouts").
    let name: String
    /// Exact bundle IDs, compared case-insensitively. Empty = not verified yet; match by name only.
    let bundleIDs: [String]
    /// Whole-word, case-insensitive match against the running app's localized name.
    let nameContains: String
}
