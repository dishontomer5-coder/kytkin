// P2-9: One remembered language choice (001 §2.2), persisted in preferences.json `rules` (§4.2, P2-8).
// JSON: { "id", "scope": { RuleScope }, "inputSource", "origin", "label"?, "updatedAt" }.
// `updatedAt` follows the encoder's date strategy; PreferencesCodec (P2-8) should use ISO 8601.
// `label` is only a user-facing name (e.g. "Slack chat 1"). It is left out of the JSON when nil.

import Foundation

struct Rule: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    var scope: RuleScope
    var inputSource: InputSourceID
    var origin: RuleOrigin
    var label: String?
    var updatedAt: Date

    init(id: UUID = UUID(), scope: RuleScope, inputSource: InputSourceID, origin: RuleOrigin,
         label: String? = nil, updatedAt: Date) {
        self.id = id
        self.scope = scope
        self.inputSource = inputSource
        self.origin = origin
        self.label = label
        self.updatedAt = updatedAt
    }
}
