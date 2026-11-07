// P3-6: THE one place a browser address string becomes a `SiteAddress` (001 §14.3.6, B12).
// The caller hands the string straight in (an AXURL's absoluteString, an unfocused address-bar value, an Apple
// Event reply) and keeps nothing: only the host and registrable domain leave this function. The string is never
// stored, cached, compared later, logged or passed on. No logging at all in Browser/ (scripts/lint.sh rule 2b).
//
// Results:
//   .site        an http(s) address with a valid host
//   .notWebPage  an explicit non-web scheme: about:, chrome://, arc://, file:, moz-extension:, … (app rules apply)
//   .unreadable  can't tell: empty, scheme-less text from any source but the Gecko bar, search terms, a broken URL.
//                The strategies turn it into `.unknown` (keep this window's last site, don't learn), never into
//                "no site" (D10: Firefox can show search terms in an unfocused bar).
// Scheme-less text ("example.co.il/news") is accepted only from `.geckoAddressBar` (P3-4): Gecko bars hide
// "https://", every other source gives a full URL. Focused bars and the Chromium omnibox never reach this function
// (D2, D16): the strategies don't read them, and there is no source for them.

enum AddressSource: Sendable {
    case axURL            // AXWebArea's AXURL (absoluteString)
    case geckoAddressBar  // the unfocused `urlbar-input` value (Zen, Firefox)
    case addressField     // Safari's unfocused WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD value (P3-11)
    case appleEvent       // an opted-in Apple Event reply (P3-7)
}

enum SiteRead: Sendable, Equatable {
    case site(SiteAddress)
    case notWebPage
    case unreadable
}

struct SiteReader: Sendable {
    private let extractor: DomainExtractor

    init(extractor: DomainExtractor) {
        self.extractor = extractor
    }

    func read(_ text: String, from source: AddressSource) -> SiteRead {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address never contains whitespace; an address bar can show search terms ("todo: milk").
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return .unreadable }
        if let scheme = DomainExtractor.explicitScheme(of: trimmed) {
            if scheme != "http" && scheme != "https" {
                // A URL source (AXURL, Apple Event) always means it. Text in an address field could be a one-word
                // query that happens to contain a colon ("note:x"), so there only the browsers' own schemes count.
                let isURLSource = source == .axURL || source == .appleEvent
                let hasAuthority = trimmed.dropFirst(scheme.count + 1).hasPrefix("//")   // "moz-extension://…"
                return isURLSource || hasAuthority || Self.internalSchemes.contains(scheme) ? .notWebPage : .unreadable
            }
            let site = extractor.extract(fromURL: trimmed)
            return site.isWebPage ? .site(site) : .unreadable   // "https://" with no valid host: can't tell
        }
        guard source == .geckoAddressBar else { return .unreadable }
        let site = extractor.extract(fromURL: trimmed)   // P3-2: rejects spaces, user info, unknown TLDs
        return site.isWebPage ? .site(site) : .unreadable
    }

    /// Non-web schemes a browser shows for its own pages in an address field (without "//").
    static let internalSchemes: Set<String> = [
        "about", "chrome", "resource", "moz-extension", "file", "view-source", "data", "blob", "javascript",
        "jar",
    ]
}
