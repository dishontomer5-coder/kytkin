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
        /// P6-3: the optional daily update check, the only network call Kytkin may make (CLAUDE.md). **Off until the
        /// user opts in** (setup screen 3 or Settings → General). A new key: the old `checkForUpdates` (true by default,
        /// never used, so never a choice) is ignored.
        var updateCheckOptedIn = false
        /// P6-3: when the last check ran (nothing else about it is stored).
        var lastUpdateCheck: Date?
        /// P2-26: the welcome window was shown once (001 §6.1). Absent → false, so a fresh install (or a file
        /// from before P2-26) shows it once. Not a privacy concern: one flag, nothing typed.
        var onboardingSeen = false

        init() {}
    }
}

extension Preferences.General: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, learnFromManualSwitches, defaultBehavior, menuBarLabel, updateCheckOptedIn, lastUpdateCheck
        case onboardingSeen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .enabled) { enabled = v }
        if let v = c.lenient(Bool.self, .learnFromManualSwitches) { learnFromManualSwitches = v }
        if let v = c.lenient(DefaultBehavior.self, .defaultBehavior) { defaultBehavior = v }
        if let v = c.lenient(MenuBarLabel.self, .menuBarLabel) { menuBarLabel = v }
        if let v = c.lenient(Bool.self, .updateCheckOptedIn) { updateCheckOptedIn = v }
        if let v = c.lenient(Date.self, .lastUpdateCheck) { lastUpdateCheck = v }
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
