// P3-2: Browser address → (host, registrable domain, isWebPage) for `site` / `siteHost` rules (001 §2.2, §4.2).
// Pure and browser-agnostic. A small hand-written authority parser instead of Foundation's URL, so the result is
// the same on every macOS version (URL's IDN and edge-case handling has changed between releases) and so the
// scheme-less text that Firefox-family address bars show ("ynet.co.il/news") works too.
//
// Rules:
// - Only http and https are web pages. Any other scheme (about:, file:, chrome:, zen:, moz-extension:,
//   chrome-extension:, safari-web-extension:, view-source:, data:, javascript:, mailto:, blob: …) → not a web page.
// - No scheme: Firefox-family address bars hide "https://", but they can also show a search query while unfocused,
//   so scheme-less text is accepted only when it can't plausibly be a search (QA P3-2): no user info ("a@b.com"),
//   and the host is `localhost`, a full dotted-quad IPv4, a bracketed IPv6, or dotted with a last label that is a
//   real top-level domain in the PSL. So "ynet.co.il/news" is a site, but "node.js", "3.5", "hello" are not.
// - User info ("user:pass@") and the port are dropped; the path, query and fragment are never looked at.
// - The host goes through HostNormalizer, exactly like RuleEngine's keys, so a context host and a saved rule
//   always compare equal. IPv6 hosts lose their brackets ("[::1]" → "::1").

import Foundation

struct DomainExtractor: Sendable {
    let suffixList: PublicSuffixList

    init(suffixList: PublicSuffixList) {
        self.suffixList = suffixList
    }

    /// Uses the bundled list (loaded lazily, once). nil only if the resource is missing.
    static var bundled: DomainExtractor? { PublicSuffixList.bundled.map(DomainExtractor.init) }

    /// Parses an address-bar string or a full URL.
    func extract(fromURL urlString: String) -> SiteAddress {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let (authority, hasScheme) = Self.authority(of: s) else { return .notWebPage }
        guard let host = Self.host(fromAuthority: authority) else { return .notWebPage }
        if !hasScheme, !looksLikeTypedAddress(host: host, authority: authority) { return .notWebPage }
        return site(forNormalizedHost: host)
    }

    /// For providers that already have a bare host. Invalid hosts → not a web page.
    func site(forHost rawHost: String) -> SiteAddress {
        var h = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        let host = HostNormalizer.normalize(h)
        guard Self.isValidHost(host) else { return .notWebPage }
        return site(forNormalizedHost: host)
    }

    private func site(forNormalizedHost host: String) -> SiteAddress {
        let domain = IPAddress.isIPLiteral(host) ? nil : suffixList.registrableDomain(forHost: host)
        return SiteAddress(host: host, registrableDomain: domain, isWebPage: true)
    }

    /// Scheme-less text: see the header. `host` is already normalized and valid.
    private func looksLikeTypedAddress(host: String, authority: Substring) -> Bool {
        guard !authority.contains("@") else { return false }
        if host == "localhost" || host.contains(":") || IPAddress.isDottedQuadIPv4(host) { return true }
        guard let dot = host.lastIndex(of: "."), !IPAddress.isIPLiteral(host) else { return false }
        return suffixList.isKnownTopLevelDomain(host[host.index(after: dot)...])
    }

    // MARK: - Parsing

    /// The authority part plus whether a scheme was present; nil when the scheme isn't http(s).
    private static func authority(of s: String) -> (Substring, Bool)? {
        var rest = Substring(s)
        var hasScheme = false
        if let colon = s.firstIndex(of: ":"), isScheme(s[..<colon]) {
            let afterColon = s[s.index(after: colon)...]
            if afterColon.hasPrefix("//") {
                let scheme = s[..<colon].lowercased()
                guard scheme == "http" || scheme == "https" else { return nil }
                rest = afterColon.dropFirst(2)
                hasScheme = true
            } else {
                // "localhost:8080/x" or "ynet.co.il:443": the "scheme" is really a host followed by a port.
                let port = afterColon.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
                guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            }
        }
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != "\\" }
        return (authority, hasScheme)
    }

    /// RFC 3986 scheme: a letter, then letters, digits, "+", "-", ".".
    private static func isScheme(_ s: Substring) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// Host from "user:pass@host:port", normalized; nil when it's empty or invalid.
    private static func host(fromAuthority authority: Substring) -> String? {
        var hostPort = authority
        if let at = hostPort.lastIndex(of: "@") { hostPort = hostPort[hostPort.index(after: at)...] }
        let raw: Substring
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            raw = hostPort[hostPort.index(after: hostPort.startIndex)..<close]
            let after = hostPort[hostPort.index(after: close)...]
            guard after.isEmpty || isPort(after) else { return nil }
            guard raw.contains(":"), raw.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        } else if let colon = hostPort.lastIndex(of: ":") {
            guard isPort(hostPort[colon...]) else { return nil }
            raw = hostPort[..<colon]
        } else {
            raw = hostPort
        }
        let host = HostNormalizer.normalize(String(raw))
        return isValidHost(host) ? host : nil
    }

    /// ":" followed by zero or more digits.
    private static func isPort(_ s: Substring) -> Bool {
        s.first == ":" && s.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A normalized host: an IPv6 literal (hex, ':' and '.'), or dot-separated non-empty labels of ASCII letters,
    /// digits, '-' and '_' (Punycode has already turned Unicode labels into ASCII).
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
}
