// P2-8: preferences.json `general` (001 §4.2, Settings → General §5.2).

import Foundation

extension Preferences {
    struct General: Sendable, Equatable {
        /// What the menu-bar item shows (001 §5.1). P6-0c (owner 2026-11-17): Kytkin's icon and the language letters
        /// by default; Settings → General can show the icon only or the letters only. A file's old `languageCode`
        /// (the only value before P6-0c, never a user choice) reads as the new default.
        enum MenuBarLabel: String, Sendable, CaseIterable {
            case iconAndLanguage, iconOnly, languageOnly
        }

        var enabled = true
        var learnFromManualSwitches = true
        /// keepCurrent by default (owner decision, 001 §11 Q3).
        var defaultBehavior: DefaultBehavior = .keepCurrent
        var menuBarLabel: MenuBarLabel = .iconAndLanguage
        /// P4-3: "Keep Kytkin up to date" (Sparkle: a daily check, install on the user's click), the only network use
        /// Kytkin may make (CLAUDE.md). **Off until the user ticks it** (setup screen 3 or Settings → General).
        /// Migrated from P6-3's `updateCheckOptedIn` (the user had chosen the daily check, which this is). The older
        /// `checkForUpdates` (true by default, never used, so never a choice) and P6-3's `lastUpdateCheck` (Sparkle
        /// keeps its own date) are ignored and dropped on the next save.
        var keepUpToDate = false
        /// P2-26: the welcome window was shown once (001 §6.1). Absent → false, so a fresh install (or a file
        /// from before P2-26) shows it once. Not a privacy concern: one flag, nothing typed.
        var onboardingSeen = false

        init() {}
    }
}

extension Preferences.General: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, learnFromManualSwitches, defaultBehavior, menuBarLabel, keepUpToDate
        case onboardingSeen
    }

    /// P4-3: keys only read (from files written by older versions), never written again.
    private enum LegacyKeys: String, CodingKey {
        case updateCheckOptedIn   // P6-3 (v1.0.0)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .enabled) { enabled = v }
        if let v = c.lenient(Bool.self, .learnFromManualSwitches) { learnFromManualSwitches = v }
        if let v = c.lenient(DefaultBehavior.self, .defaultBehavior) { defaultBehavior = v }
        if let v = c.lenient(MenuBarLabel.self, .menuBarLabel) { menuBarLabel = v }
        if let v = c.lenient(Bool.self, .keepUpToDate) {
            keepUpToDate = v
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let v = legacy.lenient(Bool.self, .updateCheckOptedIn) {
            keepUpToDate = v   // P4-3: v1.0.0's opt-in carries over
        }
        if let v = c.lenient(Bool.self, .onboardingSeen) { onboardingSeen = v }
    }
}

extension Preferences.General.MenuBarLabel: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "languageCode" { self = .iconAndLanguage; return }   // before P6-0c
        guard let v = Self(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "menuBarLabel"))
        }
        self = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
