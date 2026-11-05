// P2-9: Identifies one conversation inside a chat app (001 §2.2, Core/Model).
// Created here because RuleScope.chat needs it. P4-1/P4-2 build the extractors that produce it.
// `id` keys (Slack "T…/C…") are stored as-is; `hashed` keys are HMACs of name-based identities,
// so contact names are never persisted (design.md privacy invariants). This type never hashes:
// the extractor hands it a finished value.
// JSON: { "kind": "id" | "hashed", "value": "…" } (001 §4.2).

import Foundation

struct ChatKey: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case id, hashed }

    let kind: Kind
    let value: String

    init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}
