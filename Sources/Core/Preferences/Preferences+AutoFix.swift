// P2-8: preferences.json `autoFix` (001 §4.2). The settings exist from v1 so Phase 4 needs no
// migration; nothing reads them before P4. Defaults follow the plan.md decisions: on for confident
// words only, switch the language after a fix, Backspace right after a fix undoes it.

import Foundation

extension Preferences {
    struct AutoFix: Sendable, Equatable {
        /// plan.md decision options "on-confident / on-full"; "off" is `enabled == false`.
        enum Mode: String, Codable, Sendable, CaseIterable {
            case confidentOnly, allWords
        }

        var enabled = true
        var mode: Mode = .confidentOnly
        var switchLanguageAfterFix = true
        var backspaceUndoes = true

        init() {}
    }
}

extension Preferences.AutoFix: Codable {
    private enum CodingKeys: String, CodingKey {
        case enabled, mode, switchLanguageAfterFix, backspaceUndoes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .enabled) { enabled = v }
        if let v = c.lenient(Mode.self, .mode) { mode = v }
        if let v = c.lenient(Bool.self, .switchLanguageAfterFix) { switchLanguageAfterFix = v }
        if let v = c.lenient(Bool.self, .backspaceUndoes) { backspaceUndoes = v }
    }
}
