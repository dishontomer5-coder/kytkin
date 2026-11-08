// P2-9: Pure rule resolution (001 §2.2). Precedence: chat > siteHost > site > app > default.
// With no matching rule, DefaultBehavior decides. Its default, `keepCurrent`, leaves the language
// alone (owner decision, plan.md Phase 1, 001 §11 Q3).
//
// P3-9 (001 §14.6, owner): a site or host rule, learned or pinned, beats the browser's app rule, pinned or not;
// a browser pin is the default for sites without a rule. That is just the order below; no origin is compared.
//
// Matching details:
// - Hosts and domains match case-insensitively, ignoring one trailing dot ("Docs.Google.com." == "docs.google.com").
//   P3-2: a Unicode label also matches its Punycode form ("שלום.co.il" == "xn--9dbne9b.co.il"), via HostNormalizer.
//   Bundle IDs and chat keys match exactly.
// - Empty strings in a Context count as missing. Rules with an empty key never match.
// - Two rules for the same scope shouldn't exist (the store upserts), but the JSON file is hand-editable.
//   The winner is deterministic: pinned beats learned, then the newer `updatedAt`, then the smaller id.
// - Private windows still get site rules (001 §5 flow (d) step 5), unless `ignorePrivateWindowsCompletely`
//   is on, which drops site and siteHost rules for contexts known to be private.
// - P3-29 (plan.md decision 2026-11-08, owner): with `addressBarUsesBrowserLanguage` on, a browser whose focus is in a
//   text field outside the page (`pageState == .editingAddress`: the address bar, after ⌘L or a click) resolves as
//   the browser itself: chat (none in browsers) > app rule > `addressBarSource` (the pair's Latin member, level
//   `.addressBar`) > default. Site and host rules apply only inside web pages. Off → the old order (the site's rule
//   stays while the bar is focused). A private window gets the same.
// - P3-31 (owner decision 2026-11-08): only the real address bar counts. The Find box and other toolbar fields
//   (`.editingBrowserField`) resolve like the page: the site's rule. A field the reader can't tell apart from the bar
//   is reported as `.editingAddress` and keeps the P3-29 behaviour.

import Foundation

struct RuleEngine: Sendable {
    let defaultBehavior: DefaultBehavior
    /// Settings → Browsers & Sites → "Ignore private windows completely" (001 §8, P3).
    let ignorePrivateWindowsCompletely: Bool
    /// P3-29: Settings → Browsers & Sites → "Use the browser's language in the address bar".
    let addressBarUsesBrowserLanguage: Bool
    /// P3-29: the address bar's language when the browser has no app rule (`AddressBarLanguage.latinSource`).
    /// nil = the pair has no Latin member: the default behaviour decides.
    let addressBarSource: InputSourceID?

    /// The winning rule per normalized scope.
    private let byScope: [RuleScope: Rule]

    init(rules: [Rule], defaultBehavior: DefaultBehavior = .keepCurrent,
         ignorePrivateWindowsCompletely: Bool = false, addressBarUsesBrowserLanguage: Bool = false,
         addressBarSource: InputSourceID? = nil) {
        self.defaultBehavior = defaultBehavior
        self.ignorePrivateWindowsCompletely = ignorePrivateWindowsCompletely
        self.addressBarUsesBrowserLanguage = addressBarUsesBrowserLanguage
        self.addressBarSource = addressBarSource
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
        let inAddressBar = usesBrowserLanguage(c)   // P3-29
        let skipSites = inAddressBar || (ignorePrivateWindowsCompletely && c.isPrivateWindow == true)
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
        if inAddressBar, let source = addressBarSource {
            return Resolution(target: source, matched: nil, level: .addressBar)   // P3-29: "English"
        }
        switch defaultBehavior {
        case .keepCurrent:
            return Resolution(target: nil, matched: nil, level: .none)
        case .switchTo(let id):
            return Resolution(target: id, matched: nil, level: .defaultRule)
        }
    }

    /// P3-29: `c` is a browser whose address bar (a text field outside the page) has focus, and the setting is on.
    func usesBrowserLanguage(_ c: Context) -> Bool {
        addressBarUsesBrowserLanguage && c.pageState == .editingAddress
    }

    /// The scope a manual switch in `c` should be learned under (used by RuleLearner, P2-10).
    /// Most specific first: chat, then an existing host override, then the registrable domain, then the app.
    /// A window known to be private (`isPrivateWindow == true`) only ever learns at app level.
    /// P2-9: an existing siteHost rule is preferred over the domain, otherwise the learned domain rule
    /// would be shadowed by the override and the manual switch would have no visible effect.
    /// P3-9: unchanged (001 §14.6); it never creates a siteHost scope. RuleLearner adds the page-state guards.
    func learnableScope(for c: Context) -> RuleScope {
        guard c.isPrivateWindow != true else { return .app(bundleID: c.bundleID) }
        return pinScope(for: c)
    }

    /// P3-9 (001 §14.6, owner Q1): the scope the menu's Pin writes. `learnableScope` without the private-window
    /// guard: the user's click is the consent, so "Always use Hebrew on ynet.co.il" works in a private window too.
    /// On a site it is `site(domain)`, or the existing override `siteHost(host)`; with no site it is the app.
    /// Site and host scopes come back normalized (HostNormalizer: lowercase, no trailing dot, Punycode, D13).
    func pinScope(for c: Context) -> RuleScope {
        let bundleID = c.bundleID
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

    /// P3-5: the hosts of all siteHost rules, normalized exactly as `resolve` compares them (HostNormalizer form),
    /// for `ContextMonitoring.setHostsWithOverrides` (001 §14.5). Empty keys are left out.
    static func overrideHosts(_ rules: [Rule]) -> Set<String> {
        Set(rules.compactMap { rule -> String? in
            guard case .siteHost(let host)? = normalized(rule.scope) else { return nil }
            return host
        })
    }

    // MARK: - Normalization

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// P3-2: the shared HostNormalizer (lowercase, one trailing dot, IDN → Punycode), the same one
    /// DomainExtractor uses for context hosts, so a rule and a context always compare equal.
    private static func normalizedHost(_ s: String?) -> String? {
        HostNormalizer.normalized(s)
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
