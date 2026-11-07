// P2-20: Every rule write goes through here (001 §12 S3): learn, pin and forget. Each write collapses the other
// rules of the same normalized scope (the same normalization RuleEngine matches with), so a duplicate that a hand
// edit created heals on the first write, and no tie is ever left to `updatedAt` precision.
//
//   learn  → like `RuleLearner.upsert`: a pinned rule for the scope is never touched (and then nothing is written);
//            a learned one is updated in place (same id); otherwise a new learned rule is added.
//   pin    → the winning rule for the scope (any origin) becomes pinned with the new source (same id, label kept);
//            otherwise a new pinned rule is added.
//   forget → every rule of the scope is removed.
// Pure; the caller writes the result with `PreferencesStore.update`.

import Foundation

enum RuleWriter {
    static func learn(_ outcome: LearnOutcome, into rules: [Rule], now: Date, newID: UUID = UUID()) -> [Rule] {
        guard case .learn(let scope, let source) = outcome else { return rules }
        if let existing = RuleEngine(rules: rules).rule(for: scope) {
            guard existing.origin == .learned else { return rules }   // pins stay fixed (001 §11 Q2)
            var updated = existing
            updated.inputSource = source
            updated.updatedAt = now
            return replacingScope(of: existing.scope, in: rules, with: updated)
        }
        return rules + [Rule(id: newID, scope: scope, inputSource: source, origin: .learned, updatedAt: now)]
    }

    static func pin(_ scope: RuleScope, to source: InputSourceID, in rules: [Rule], now: Date,
                    newID: UUID = UUID()) -> [Rule] {
        guard RuleEngine.normalized(scope) != nil else { return rules }   // an empty key can never match
        if let existing = RuleEngine(rules: rules).rule(for: scope) {
            var updated = existing
            updated.inputSource = source
            updated.origin = .pinned
            updated.updatedAt = now
            return replacingScope(of: existing.scope, in: rules, with: updated)
        }
        return rules + [Rule(id: newID, scope: scope, inputSource: source, origin: .pinned, updatedAt: now)]
    }

    static func forget(_ scope: RuleScope, in rules: [Rule]) -> [Rule] {
        guard let key = RuleEngine.normalized(scope) else { return rules }
        return rules.filter { RuleEngine.normalized($0.scope) != key }
    }

    /// `rules` with every rule of `scope` removed and `rule` put where the first of them was (order kept).
    private static func replacingScope(of scope: RuleScope, in rules: [Rule], with rule: Rule) -> [Rule] {
        let key = RuleEngine.normalized(scope)
        var result: [Rule] = []
        var placed = false
        for r in rules {
            if RuleEngine.normalized(r.scope) == key {
                if !placed { result.append(rule); placed = true }
            } else {
                result.append(r)
            }
        }
        if !placed { result.append(rule) }
        return result
    }
}
