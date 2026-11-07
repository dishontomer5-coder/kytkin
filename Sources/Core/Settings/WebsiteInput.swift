// P3-15 (001 §14.8, D7, D13, D14): what the user typed into Rules → "Add Website…", reduced to the rule it can make.
// The only way to create a website or single-address (siteHost) rule by hand.
//
// - Parsed by `DomainExtractor.extract(fromURL:)`, so a typed domain ("ynet.co.il") or a pasted URL
//   ("https://news.ynet.co.il/a?b=1") both work; only the host is kept (never the path or query), already through
//   HostNormalizer (lowercase, no trailing dot, Punycode).
// - A host that is itself a public suffix (`gov.il`, `github.io`, a bare TLD) can't be a site: it is refused with a
//   hint to enter one site under it.
// - The host differs from its registrable domain → a choice: all of the site (`site`) or only this address
//   (`siteHost`). The whole site is the default.
// - An IP, `localhost` or a one-label intranet name has no registrable domain → a `site` rule keyed by the host
//   (D14, exactly the key ContextAssembler uses as `siteKey`).
// Every text shown here uses `HostNormalizer.unicodeForm`; the scopes carry the Punycode keys.

import Foundation

enum WebsiteInput: Equatable, Sendable {
    /// Nothing typed yet.
    case empty
    /// Not a web address (a search word, `about:`, `file:`…).
    case invalid
    /// The host is a public suffix shared by many sites. Carries the normalized host.
    case sharedSuffix(String)
    /// Exactly one possible rule: `site(key)` (the host is the registrable domain, or an IP / localhost / intranet name).
    case single(siteKey: String, isHostOnly: Bool)
    /// A subdomain: all of `site`, or only `host`.
    case choice(site: String, host: String)

    static func parse(_ text: String, extractor: DomainExtractor) -> WebsiteInput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let address = extractor.extract(fromURL: trimmed)
        guard address.isWebPage, let host = address.host else { return .invalid }
        if let domain = address.registrableDomain {
            return domain == host ? .single(siteKey: domain, isHostOnly: false) : .choice(site: domain, host: host)
        }
        // No registrable domain: an IP, localhost, an intranet name, or a public suffix.
        if IPAddress.isIPLiteral(host) || host == "localhost" { return .single(siteKey: host, isHostOnly: true) }
        let isSuffix = host.contains(".")
            ? extractor.suffixList.publicSuffix(forHost: host) == host
            : extractor.suffixList.isKnownTopLevelDomain(Substring(host))
        return isSuffix ? .sharedSuffix(host) : .single(siteKey: host, isHostOnly: true)
    }

    /// Whole site or only the typed address, for `.choice`.
    enum Extent: String, CaseIterable, Identifiable, Sendable {
        case wholeSite, onlyHost
        var id: String { rawValue }
    }

    /// The rule Save writes; nil when nothing can be saved.
    func scope(extent: Extent) -> RuleScope? {
        switch self {
        case .empty, .invalid, .sharedSuffix: nil
        case .single(let key, _): .site(domain: key)
        case .choice(let site, let host): extent == .wholeSite ? .site(domain: site) : .siteHost(host: host)
        }
    }

    /// The line under the field: a refusal, or what the rule will cover. nil when the field is empty.
    var message: String? {
        switch self {
        case .empty: nil
        case .invalid: "Enter a website address, like ynet.co.il or a link copied from your browser."
        case .sharedSuffix(let host):
            "\(HostNormalizer.unicodeForm(host)) is shared by many websites. Enter one site, like "
                + "www.\(HostNormalizer.unicodeForm(host))."
        case .single(let key, let hostOnly):
            hostOnly ? "Only \(HostNormalizer.unicodeForm(key))"
                : "All of \(HostNormalizer.unicodeForm(key)), including its subdomains"
        case .choice: nil   // the two choices say it
        }
    }

    /// The two choices' titles for `.choice`: "All of ynet.co.il", "Only news.ynet.co.il".
    func title(for extent: Extent) -> String? {
        guard case .choice(let site, let host) = self else { return nil }
        return extent == .wholeSite ? "All of \(HostNormalizer.unicodeForm(site))"
            : "Only \(HostNormalizer.unicodeForm(host))"
    }
}
