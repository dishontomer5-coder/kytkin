// P2-8: preferences.json `general` (001 §4.2, Settings → General §5.2).

import Foundation

extension Preferences {
    struct General: Sendable, Equatable {
        /// What the menu-bar title shows. Only the language code exists in v1 (001 §5.1).
        enum MenuBarLabel: String, Codable, Sendable, CaseIterable {
            case languageCode
        }

        var enabled = true
        var learnFromManualSwitches = true
        /// keepCurrent by default (owner decision, 001 §11 Q3).
        var defaultBehavior: DefaultBehavior = .keepCurrent
        var menuBarLabel: MenuBarLabel = .languageCode
        /// The optional daily update check (P6). The only network call Kytkin may make.
        var checkForUpdates = true

        init() {}
    }
}

extension Preferences.General: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, learnFromManualSwitches, defaultBehavior, menuBarLabel, checkForUpdates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .enabled) { enabled = v }
        if let v = c.lenient(Bool.self, .learnFromManualSwitches) { learnFromManualSwitches = v }
        if let v = c.lenient(DefaultBehavior.self, .defaultBehavior) { defaultBehavior = v }
        if let v = c.lenient(MenuBarLabel.self, .menuBarLabel) { menuBarLabel = v }
        if let v = c.lenient(Bool.self, .checkForUpdates) { checkForUpdates = v }
    }
}
