// P3-2: What DomainExtractor gets out of a browser address: only the host and its registrable domain, never the
// path, query, port or user info (design.md: persist only bare domains/hosts; 001 §2.2 BrowserTab).

struct SiteAddress: Sendable, Equatable {
    /// Normalized host (HostNormalizer: lowercase, Punycode, no trailing dot; IPv6 without brackets).
    /// nil when this isn't a web page.
    let host: String?
    /// eTLD+1 from the Public Suffix List. nil for IPs, `localhost`, single-label hosts, a host that is itself a
    /// public suffix (`idf.il`, `github.io`), and non-web pages.
    let registrableDomain: String?
    /// true only for http(s) pages (or a scheme-less address that looks like a host). `about:`, `file:`,
    /// `chrome:`, `zen:`, extension pages and the like are false: they get no site rule (app rules apply).
    let isWebPage: Bool

    /// The key a `site` rule uses (001 §4.2): the registrable domain, or the host itself when there is none
    /// (an IP, `localhost`, an intranet name). nil for non-web pages.
    var siteKey: String? { registrableDomain ?? host }

    static let notWebPage = SiteAddress(host: nil, registrableDomain: nil, isWebPage: false)
}
