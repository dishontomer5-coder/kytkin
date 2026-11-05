// P2-13: The other input switchers ConflictDetector (P2-19) looks for in NSWorkspace.runningApplications.
// Detection only: Kytkin warns and never quits or changes another app (design.md).
//
// Sources (clean-room): FlicKey's bundle ID was observed from the app installed on the owner's Mac
// (Spotlight metadata `kMDItemCFBundleIdentifier` of /Applications/FlicKey.app, 2026-11-05), never from its
// repository. The other apps are named in R1 / 001 but aren't installed here, so they match by name only
// until their bundle IDs are verified from each app's public metadata (001: "verified while building").

import Foundation

enum KnownSwitchers {
    static let entries: [KnownSwitcher] = [
        KnownSwitcher(name: "FlicKey", bundleIDs: ["com.talalfi.FlicKey"], nameContains: "FlicKey"),
        KnownSwitcher(name: "Input Source Pro", bundleIDs: [], nameContains: "Input Source Pro"),
        KnownSwitcher(name: "Kawa", bundleIDs: [], nameContains: "Kawa"),
        KnownSwitcher(name: "Punto Switcher", bundleIDs: [], nameContains: "Punto Switcher"),
        KnownSwitcher(name: "Caramba Switcher", bundleIDs: [], nameContains: "Caramba"),
    ]

    /// Kytkin's own bundle IDs (Release and Debug) never count as a conflict.
    static let ownBundleIDPrefix = "io.github.kytkin."

    /// The switcher a running app is, if any. The bundle ID is checked first, then the name.
    static func match(bundleID: String?, name: String?, in entries: [KnownSwitcher] = entries) -> KnownSwitcher? {
        let id = bundleID.map(normalized) ?? ""
        if id.hasPrefix(ownBundleIDPrefix) { return nil }
        if !id.isEmpty, let hit = entries.first(where: { $0.bundleIDs.contains { normalized($0) == id } }) {
            return hit
        }
        guard let name, !name.isEmpty else { return nil }
        let words = tokens(name)
        return entries.first { e in
            let needle = tokens(e.nameContains)
            return !needle.isEmpty && containsRun(words, needle)
        }
    }

    /// Display names of the switchers among running apps, deduplicated, in `entries` order.
    static func running(in apps: [(bundleID: String?, name: String?)],
                        entries: [KnownSwitcher] = entries) -> [String] {
        let hits = Set(apps.compactMap { match(bundleID: $0.bundleID, name: $0.name, in: entries)?.name })
        return entries.map(\.name).filter(hits.contains)
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Lowercased alphanumeric words, so "Kawa" matches "Kawa" and "kawa 2" but not "Kawasaki".
    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func containsRun(_ hay: [String], _ needle: [String]) -> Bool {
        guard needle.count <= hay.count else { return false }
        return (0...(hay.count - needle.count)).contains { Array(hay[$0..<$0 + needle.count]) == needle }
    }
}
