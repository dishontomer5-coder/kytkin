// P3-2: The one host normalization shared by RuleEngine, ContextAssembler, PublicSuffixList and DomainExtractor
// (001 §2.2 "DomainExtractor", §4.2; P2-41 noted RuleEngine and ContextAssembler each had their own copy).
//
// normalize(_:) = lowercase, drop ONE trailing dot ("Docs.Google.com." → "docs.google.com"), and turn each
// non-ASCII label into Punycode ("שלום.co.il" → "xn--9dbne9b.co.il"), so a rule a user typed in Unicode and the
// host the browser reports compare equal. ASCII hosts only get the first two steps (cheap fast path).
// IDN handling is NFC + lowercase per label, not full UTS #46 mapping (enough for real addresses, which browsers
// already show mapped; noted in the P3-2 report).

import Foundation

enum HostNormalizer {
    /// Normalized form; may be empty (callers decide what an empty host means).
    static func normalize(_ host: String) -> String {
        var h = host
        if h.hasSuffix(".") { h.removeLast() }
        if h.utf8.allSatisfy({ $0 < 0x80 }) { return h.lowercased() }
        return h.split(separator: ".", omittingEmptySubsequences: false)
            .map { asciiLabel(String($0)) }
            .joined(separator: ".")
    }

    /// nil for nil or a host that normalizes to "" (RuleEngine: an empty key never matches).
    static func normalized(_ host: String?) -> String? {
        guard let host else { return nil }
        let h = normalize(host)
        return h.isEmpty ? nil : h
    }

    /// For display only (Settings): "xn--9dbne9b.co.il" → "שלום.co.il". Labels that aren't valid Punycode stay as is.
    static func unicodeForm(_ host: String) -> String {
        host.split(separator: ".", omittingEmptySubsequences: false).map { label -> String in
            guard label.lowercased().hasPrefix("xn--"),
                  let decoded = Punycode.decode(String(label.dropFirst(4))), !decoded.isEmpty else { return String(label) }
            return decoded
        }.joined(separator: ".")
    }

    private static func asciiLabel(_ label: String) -> String {
        let lower = label.precomposedStringWithCanonicalMapping.lowercased()
        guard !lower.utf8.allSatisfy({ $0 < 0x80 }) else { return lower }
        guard let encoded = Punycode.encode(lower) else { return lower }
        return "xn--" + encoded
    }
}
