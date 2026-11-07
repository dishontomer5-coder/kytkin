// P2-9: Pure rule resolution (001 §2.2). Precedence: chat > siteHost > site > app > default.
// With no matching rule, DefaultBehavior decides. Its default, `keepCurrent`, leaves the language
// alone (owner decision, plan.md Phase 1, 001 §11 Q3).
//
// Matching details:
// - Hosts and domains match case-insensitively, ignoring one trailing dot ("Docs.Google.com." == "docs.google.com").
//   Bundle IDs and chat keys match exactly.
// - Empty strings in a Context count as missing. Rules with an empty key never match.
// - Two rules for the same scope shouldn't exist (the store upserts), but the JSON file is hand-editable.
//   The winner is deterministic: pinned beats learned, then the newer `updatedAt`, then the smaller id.
// - Private windows still get site rules (001 §5 flow (d) step 5), unless `ignorePrivateWindowsCompletely`
//   is on, which drops site and siteHost rules for contexts known to be private.

import Foundation

struct RuleEngine: Sendable {
    let defaultBehavior: DefaultBehavior
    /// Settings → Browsers & Sites → "Ignore private windows completely" (001 §8, P3).
    let ignorePrivateWindowsCompletely: Bool

    /// The winning rule per normalized scope.
    private let byScope: [RuleScope: Rule]

    init(rules: [Rule], defaultBehavior: DefaultBehavior = .keepCurrent,
         ignorePrivateWindowsCompletely: Bool = false) {
        self.defaultBehavior = defaultBehavior
        self.ignorePrivateWindowsCompletely = ignorePrivateWindowsCompletely
        var index: [RuleScope: Rule] = [:]
        for rule in rules {
            guard let key = Self.normalized(rule.scope) else { continue }
            if let existing = index[key], !Self.beats(rule, existing) { continue }
            index[key] = rule
        }
        byScope = index
    }

    /// The language to use in `c`, and why.
    func resolve(_ c: Context) -> Resolution {
        let bundleID = Self.nonEmpty(c.bundleID)
        if let bundleID, let key = c.chatKey, let rule = byScope[.chat(bundleID: bundleID, key: key)] {
            return Resolution(target: rule.inputSource, matched: rule, level: .chat)
        }
        let skipSites = ignorePrivateWindowsCompletely && c.isPrivateWindow == true
        if !skipSites {
            if let host = Self.normalizedHost(c.host), let rule = byScope[.siteHost(host: host)] {
                return Resolution(target: rule.inputSource, matched: rule, level: .siteHost)
            }
            if let domain = Self.normalizedHost(c.siteDomain), let rule = byScope[.site(domain: domain)] {
                return Resolution(target: rule.inputSource, matched: rule, level: .site)
            }
        }
        if let bundleID, let rule = byScope[.app(bundleID: bundleID)] {
            return Resolution(target: rule.inputSource, matched: rule, level: .app)
        }
        switch defaultBehavior {
        case .keepCurrent:
            return Resolution(target: nil, matched: nil, level: .none)
        case .switchTo(let id):
            return Resolution(target: id, matched: nil, level: .defaultRule)
        }
    }

    /// The scope a manual switch in `c` should be learned under (used by RuleLearner, P2-10).
    /// Most specific first: chat, then an existing host override, then the registrable domain, then the app.
    /// A window known to be private (`isPrivateWindow == true`) only ever learns at app level.
    /// P2-9: an existing siteHost rule is preferred over the domain, otherwise the learned domain rule
    /// would be shadowed by the override and the manual switch would have no visible effect.
    func learnableScope(for c: Context) -> RuleScope {
        let bundleID = c.bundleID
        guard c.isPrivateWindow != true else { return .app(bundleID: bundleID) }
        if let key = c.chatKey, Self.nonEmpty(bundleID) != nil, !key.value.isEmpty {
            return .chat(bundleID: bundleID, key: key)
        }
        if let host = Self.normalizedHost(c.host), byScope[.siteHost(host: host)] != nil {
            return .siteHost(host: host)
        }
        if let domain = Self.normalizedHost(c.siteDomain) {
            return .site(domain: domain)
        }
        return .app(bundleID: bundleID)
    }

    /// The rule stored for exactly this scope, if any (after the same normalization `resolve` uses).
    /// Lets RuleLearner check "never overwrite a pinned rule".
    func rule(for scope: RuleScope) -> Rule? {
        guard let key = Self.normalized(scope) else { return nil }
        return byScope[key]
    }

    // MARK: - Normalization

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    private static func normalizedHost(_ s: String?) -> String? {
        guard var h = s?.lowercased() else { return nil }
        if h.hasSuffix(".") { h.removeLast() }
        return h.isEmpty ? nil : h
    }

    /// nil = the rule can never match (empty key).
    /// P2-20: internal (was private) so `RuleWriter` collapses duplicates with exactly the matching rule (001 §12 S3).
    static func normalized(_ scope: RuleScope) -> RuleScope? {
        switch scope {
        case .app(let bundleID):
            return nonEmpty(bundleID).map { .app(bundleID: $0) }
        case .site(let domain):
            return normalizedHost(domain).map { .site(domain: $0) }
        case .siteHost(let host):
            return normalizedHost(host).map { .siteHost(host: $0) }
        case .chat(let bundleID, let key):
            guard nonEmpty(bundleID) != nil, !key.value.isEmpty else { return nil }
            return scope
        }
    }

    /// Deterministic tie-break for duplicate scopes: pinned > learned, newer > older, smaller id.
    private static func beats(_ a: Rule, _ b: Rule) -> Bool {
        if a.origin != b.origin { return a.origin == .pinned }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id.uuidString < b.id.uuidString
    }
}
