// P2-8: One entry of preferences.json `apps` (001 §4.2): the user's differences from the shipped
// per-app defaults. Every field is optional; nil means "use the shipped default", and nil fields are
// left out of the JSON. An unknown `replacementMethod` decodes as nil.

import Foundation

extension Preferences {
    struct AppOverride: Codable, Sendable, Equatable {
        /// The user's text-method override (Settings → Apps; 001 §2.2 `MethodHint`, minus `disabled`,
        /// which is `AppOverride.disabled`).
        enum ReplacementMethod: String, Codable, Sendable, CaseIterable {
            case auto, keysOnly, noUnicode, preferPaste
        }

        /// Kytkin does nothing in this app.
        var disabled: Bool?
        var convertEnabled: Bool?
        var autoFixEnabled: Bool?
        var replacementMethod: ReplacementMethod?

        init(disabled: Bool? = nil, convertEnabled: Bool? = nil, autoFixEnabled: Bool? = nil,
             replacementMethod: ReplacementMethod? = nil) {
            self.disabled = disabled
            self.convertEnabled = convertEnabled
            self.autoFixEnabled = autoFixEnabled
            self.replacementMethod = replacementMethod
        }

        private enum CodingKeys: String, CodingKey {
            case disabled, convertEnabled, autoFixEnabled, replacementMethod
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            disabled = c.lenient(Bool.self, .disabled)
            convertEnabled = c.lenient(Bool.self, .convertEnabled)
            autoFixEnabled = c.lenient(Bool.self, .autoFixEnabled)
            replacementMethod = c.lenient(ReplacementMethod.self, .replacementMethod)
        }
    }
}
