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

    /// QA P3-2: a label that can't be a real IDN label is left in Unicode, so every host check (all ASCII) rejects it
    /// instead of it becoming a plausible-looking "xn--…" host: more than 63 code points (its Punycode would be
    /// longer than the 63-byte label limit anyway, and this bounds Punycode's quadratic encoder), or a character no
    /// browser allows in a host (controls, bidi and other format characters, spaces, private-use, unassigned, and
    /// U+FFFD, which is what invalid UTF-16 turns into). ZWNJ/ZWJ stay allowed (IDNA2008 permits them in context).
    private static func asciiLabel(_ label: String) -> String {
        let lower = label.precomposedStringWithCanonicalMapping.lowercased()
        guard !lower.utf8.allSatisfy({ $0 < 0x80 }) else { return lower }
        guard lower.unicodeScalars.count <= 63, lower.unicodeScalars.allSatisfy(isAllowedInIDNLabel),
              let encoded = Punycode.encode(lower) else { return lower }
        return "xn--" + encoded
    }

    private static func isAllowedInIDNLabel(_ s: Unicode.Scalar) -> Bool {
        if s.value == 0x200C || s.value == 0x200D { return true }
        if s.value == 0xFFFD { return false }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }
}
