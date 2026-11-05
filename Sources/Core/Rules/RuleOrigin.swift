// P2-9: Who made a rule (001 §2.2). `pinned` = set by the user in the menu or Settings;
// `learned` = committed by RuleLearner from manual switches. Learning never overwrites a pinned
// rule (owner decision, plan.md Phase 1). JSON raw values: "learned", "pinned" (001 §4.2).

import Foundation

enum RuleOrigin: String, Codable, Sendable, CaseIterable {
    case learned, pinned
}
