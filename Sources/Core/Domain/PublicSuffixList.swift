// P3-2: Public Suffix List matcher (001 §2.2 "DomainExtractor", R3 §5). Pure; the list itself is the bundled,
// unmodified `public_suffix_list.dat` (MPL-2.0, see THIRD_PARTY_NOTICES.md), refreshed only by `scripts/update-psl`.
// The app never fetches it.
//
// Algorithm (https://github.com/publicsuffix/list/wiki/Format):
// - A rule matches a host when its labels equal the host's rightmost labels; `*` matches any one label.
// - An exception rule (`!`) always wins; its public suffix is the rule minus its leftmost label.
// - Otherwise the matching rule with the most labels wins. No match → the implicit rule `*` (the TLD).
// - Registrable domain = public suffix + one more label. A host that IS a public suffix has none (nil).
// Rules are lowercased and Punycoded on load (the file lists IDN suffixes in Unicode), so all matching is ASCII.
//
// Implementation: one table from a suffix ("co.il") to flags. Besides the three rule kinds it marks "inner"
// suffixes that some longer rule ends with, so a lookup walks the host from the TLD leftwards and stops at the
// first suffix nothing longer can match: usually 2–3 hash lookups per host, on slices of the host (no string
// building). 10k lookups take ~10 ms optimized, well under the 50 ms budget even in Debug test builds.
//
// PRIVATE section (P3-2 decision, see report): included by default, like browsers do for cookies. So
// `alice.github.io` and `bob.github.io` are different sites, and so are two `*.ravpage.co.il` landing pages.
// `includePrivateDomains: false` gives the ICANN-only view.

import Foundation

struct PublicSuffixList: Sendable {
    private struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let rule = Flags(rawValue: 1)        // "co.il"
        static let wildcard = Flags(rawValue: 2)    // "*.ck" → set on "ck"
        static let exception = Flags(rawValue: 4)   // "!www.ck" → set on "www.ck"
        static let inner = Flags(rawValue: 8)       // a longer rule of any kind ends with this suffix
    }

    private let table: [Substring: Flags]

    /// Number of rules loaded (all three kinds).
    let ruleCount: Int

    init(datContents: String, includePrivateDomains: Bool = true) {
        var table: [Substring: Flags] = [:]
        table.reserveCapacity(16_000)
        var count = 0
        // Each line: the rule is everything up to the first whitespace; `//` lines are comments. Byte-level
        // splitting (the file is UTF-8 and every separator is ASCII) keeps the one-time load fast.
        for lineBytes in datContents.utf8.split(separator: UInt8(ascii: "\n")) {
            let line = Substring(lineBytes)
            if line.hasPrefix("//") {
                if !includePrivateDomains, line.contains("===BEGIN PRIVATE DOMAINS===") { break }
                continue
            }
            guard let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).first else {
                continue
            }
            let kind: Flags
            var body = token
            if body.hasPrefix("!") {
                kind = .exception
                body = body.dropFirst()
            } else if body.hasPrefix("*.") {
                kind = .wildcard
                body = body.dropFirst(2)
            } else {
                kind = .rule
            }
            let key = HostNormalizer.normalize(String(body))
            guard !key.isEmpty else { continue }
            count += 1
            table[Substring(key), default: []].insert(kind)
            // Mark every shorter suffix of this rule as `inner`, so the walk knows to keep going past it.
            var rest = Substring(key)
            while let dot = rest.firstIndex(of: ".") {
                rest = rest[rest.index(after: dot)...]
                table[Substring(String(rest)), default: []].insert(.inner)
            }
        }
        self.table = table
        self.ruleCount = count
    }

    /// The bundled list, loaded lazily on first use and once per process (a `static let` is lazy and thread-safe).
    /// nil only if the resource is missing from the bundle (a packaging bug; tests cover it).
    static let bundled: PublicSuffixList? = {
        guard let url = bundledURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PublicSuffixList(datContents: text)
    }()

    /// `public_suffix_list.dat` in the bundle that holds this code: the app in the app, the test bundle in tests.
    static var bundledURL: URL? {
        Bundle(for: BundleToken.self).url(forResource: "public_suffix_list", withExtension: "dat")
    }

    private final class BundleToken {}

    /// P3-15: the list's `// VERSION:` header line ("2026-11-06_09-01-47_UTC"), for About's acknowledgements.
    /// Only the first lines are looked at; nil when there is no such line.
    static func version(inHeader text: Substring) -> String? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("//") else { continue }
            let body = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("VERSION:") else { continue }
            let v = body.dropFirst("VERSION:".count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// P3-15: the bundled list's version (the first 4 KB of the file are read; nil if it is missing).
    static var bundledVersion: String? {
        guard let url = bundledURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return nil }
        return version(inHeader: Substring(String(decoding: data, as: UTF8.self)))
    }

    // MARK: - Matching

    /// The registrable domain (eTLD+1) of `host`, normalized (lowercase, ASCII/Punycode, no trailing dot):
    /// "www.ynet.co.il" → "ynet.co.il". nil for an IP literal, an invalid host (empty label), or a host that is
    /// itself a public suffix ("co.il", "localhost", "example"). The caller uses the host as the site key then.
    func registrableDomain(forHost host: String) -> String? {
        guard let parsed = Self.parse(host) else { return nil }
        let suffixCount = publicSuffixLabelCount(parsed)
        let n = parsed.starts.count
        guard n > suffixCount else { return nil }
        return String(parsed.host[parsed.starts[n - suffixCount - 1]...])
    }

    /// The public suffix of `host` ("www.ynet.co.il" → "co.il"); nil for IP literals and invalid hosts.
    func publicSuffix(forHost host: String) -> String? {
        guard let parsed = Self.parse(host) else { return nil }
        return String(parsed.host[parsed.starts[parsed.starts.count - publicSuffixLabelCount(parsed)]...])
    }

    /// Whether `label` (normalized: lowercase ASCII/Punycode) is a top-level domain some rule ends with ("il",
    /// "com", "xn--4dbrk0ce"). "js" or "txt" aren't. Lets DomainExtractor tell "node.js" (a search) from an address.
    func isKnownTopLevelDomain(_ label: Substring) -> Bool {
        !label.isEmpty && !label.contains(".") && table[label] != nil
    }

    /// A normalized host and the start index of each label, so every suffix is a slice.
    private struct ParsedHost {
        let host: Substring
        let starts: [String.Index]   // starts[i] = first byte of label i; suffix(i) = host[starts[i]...]
    }

    /// nil for an empty/invalid host (an empty label) or an IP literal.
    private static func parse(_ raw: String) -> ParsedHost? {
        let h = HostNormalizer.normalize(raw)
        guard !h.isEmpty, !IPAddress.isIPLiteral(h) else { return nil }
        let bytes = h.utf8
        var starts = [bytes.startIndex]
        var i = bytes.startIndex
        while i != bytes.endIndex {
            if bytes[i] == UInt8(ascii: ".") {
                let next = bytes.index(after: i)
                guard i != starts[starts.count - 1], next != bytes.endIndex else { return nil }   // empty label
                starts.append(next)
            }
            bytes.formIndex(after: &i)
        }
        return ParsedHost(host: Substring(h), starts: starts)
    }

    /// How many of the rightmost labels form the public suffix (always ≥ 1, never more than the label count).
    private func publicSuffixLabelCount(_ p: ParsedHost) -> Int {
        let n = p.starts.count
        var best = 1                                    // the implicit "*" rule
        var i = n - 1                                   // suffix(i) = labels[i...]; start at the TLD
        while i >= 0 {
            guard let flags = table[p.host[p.starts[i]...]] else { break }
            if flags.contains(.exception) { return max(1, n - i - 1) }   // exceptions always win
            if flags.contains(.rule) { best = n - i }
            if flags.contains(.wildcard), i > 0 { best = n - i + 1 }       // "*.<this>" covers one more label
            guard flags.contains(.inner) || flags.contains(.wildcard) else { break }
            i -= 1
        }
        return best
    }
}
