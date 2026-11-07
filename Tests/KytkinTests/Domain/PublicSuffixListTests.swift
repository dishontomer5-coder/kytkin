// P3-2: PublicSuffixList: the official PSL test vectors (Fixtures/psl/test_psl.txt, same commit as the bundled
// list), Israeli and UK domains, wildcard/exception rules, IDN, IPs, the PRIVATE-section switch, the bundled
// resource, load time and lookup speed.

import XCTest

final class PublicSuffixListTests: XCTestCase {
    private static let list: PublicSuffixList? = PublicSuffixList.bundled

    private func psl(file: StaticString = #filePath, line: UInt = #line) throws -> PublicSuffixList {
        try XCTUnwrap(Self.list, "public_suffix_list.dat is missing from the bundle", file: file, line: line)
    }

    // MARK: - Bundled resource

    func testBundledListLoadsWithBothSections() throws {
        let list = try psl()
        XCTAssertGreaterThan(list.ruleCount, 9_000)
        // ICANN-only drops the PRIVATE section (thousands of rules).
        let text = try String(contentsOf: XCTUnwrap(PublicSuffixList.bundledURL), encoding: .utf8)
        let icann = PublicSuffixList(datContents: text, includePrivateDomains: false)
        XCTAssertGreaterThan(list.ruleCount - icann.ruleCount, 2_000)
        XCTAssertTrue(text.hasPrefix("// This Source Code Form is subject to the terms of the Mozilla Public"),
                      "the list must be shipped unmodified, MPL header intact")
    }

    func testBundledListIsLoadedOnce() throws {
        // `bundled` is a static let: the same storage every time (no reload per call).
        let a = try XCTUnwrap(PublicSuffixList.bundled), b = try XCTUnwrap(PublicSuffixList.bundled)
        XCTAssertEqual(a.ruleCount, b.ruleCount)
    }

    // MARK: - Official test vectors

    func testOfficialPSLTestVectors() throws {
        let list = try psl()
        let text = try String(contentsOf: Fixtures.url("psl/test_psl.txt"), encoding: .utf8)
        let cases = Self.parseVectors(text)
        XCTAssertGreaterThan(cases.count, 70, "parsed too few vectors from test_psl.txt")
        for (input, expected) in cases {
            // `checkPublicSuffix(null, null)`: no host, nothing to check.
            guard let input else { continue }
            let got = list.registrableDomain(forHost: input)
            // Unicode expectations are compared in their normalized (Punycode) form, which is what Kytkin stores.
            XCTAssertEqual(got, expected.map(HostNormalizer.normalize), "checkPublicSuffix('\(input)')")
        }
    }

    /// `checkPublicSuffix('a', 'b');` / `null` lines; commented-out lines are skipped.
    private static func parseVectors(_ text: String) -> [(String?, String?)] {
        func arg(_ s: Substring) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t != "null" else { return nil }
            return String(t.dropFirst().dropLast())   // strip the quotes
        }
        var out: [(String?, String?)] = []
        text.enumerateLines { line, _ in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("checkPublicSuffix("), let close = l.lastIndex(of: ")") else { return }
            let inner = l[l.index(l.startIndex, offsetBy: "checkPublicSuffix(".count)..<close]
            let parts = inner.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { return }
            out.append((arg(parts[0]), arg(parts[1])))
        }
        return out
    }

    // MARK: - Israeli domains

    func testIsraeliDomains() throws {
        let list = try psl()
        XCTAssertEqual(list.registrableDomain(forHost: "www.ynet.co.il"), "ynet.co.il")
        XCTAssertEqual(list.registrableDomain(forHost: "ynet.co.il"), "ynet.co.il")
        XCTAssertEqual(list.registrableDomain(forHost: "m.ynet.co.il"), "ynet.co.il")
        // gov.il and idf.il are public suffixes themselves, so each subdomain is its own site.
        XCTAssertEqual(list.registrableDomain(forHost: "www.gov.il"), "www.gov.il")
        XCTAssertEqual(list.registrableDomain(forHost: "a.b.gov.il"), "b.gov.il")
        XCTAssertNil(list.registrableDomain(forHost: "gov.il"))
        XCTAssertNil(list.registrableDomain(forHost: "idf.il"))
        XCTAssertEqual(list.registrableDomain(forHost: "www.idf.il"), "www.idf.il")
        XCTAssertEqual(list.registrableDomain(forHost: "www.technion.ac.il"), "technion.ac.il")
        XCTAssertNil(list.registrableDomain(forHost: "co.il"))
        XCTAssertNil(list.registrableDomain(forHost: "il"))
        XCTAssertEqual(list.publicSuffix(forHost: "www.ynet.co.il"), "co.il")
    }

    func testIsraeliIDN() throws {
        let list = try psl()
        XCTAssertEqual(list.registrableDomain(forHost: "שלום.co.il"), "xn--9dbne9b.co.il")
        XCTAssertEqual(list.registrableDomain(forHost: "www.שלום.co.il"), "xn--9dbne9b.co.il")
        XCTAssertEqual(list.registrableDomain(forHost: "דוגמה.ישראל"), "xn--6dbbec0c.xn--4dbrk0ce")
        XCTAssertEqual(list.registrableDomain(forHost: "www.xn--6dbbec0c.xn--4dbrk0ce"), "xn--6dbbec0c.xn--4dbrk0ce")
        XCTAssertNil(list.registrableDomain(forHost: "ישראל"))
        // A second-level IDN suffix under ישראל (rules are Punycoded on load).
        XCTAssertNil(list.registrableDomain(forHost: "ממשל.ישראל"))
        XCTAssertEqual(list.registrableDomain(forHost: "www.משרד.ממשל.ישראל"),
                       HostNormalizer.normalize("משרד.ממשל.ישראל"))
    }

    // MARK: - Other suffix shapes

    func testUKAndCommon() throws {
        let list = try psl()
        XCTAssertEqual(list.registrableDomain(forHost: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertNil(list.registrableDomain(forHost: "co.uk"))
        XCTAssertEqual(list.registrableDomain(forHost: "mail.google.com"), "google.com")
        XCTAssertEqual(list.registrableDomain(forHost: "claude.ai"), "claude.ai")
        XCTAssertEqual(list.registrableDomain(forHost: "WWW.Example.COM."), "example.com")
    }

    func testWildcardAndExceptionRules() throws {
        let list = try psl()
        XCTAssertNil(list.registrableDomain(forHost: "ck"))
        XCTAssertNil(list.registrableDomain(forHost: "anything.ck"))          // *.ck
        XCTAssertEqual(list.registrableDomain(forHost: "b.anything.ck"), "b.anything.ck")
        XCTAssertEqual(list.registrableDomain(forHost: "www.ck"), "www.ck")   // !www.ck
        XCTAssertEqual(list.registrableDomain(forHost: "a.www.ck"), "www.ck")
        XCTAssertEqual(list.publicSuffix(forHost: "a.www.ck"), "ck")
    }

    func testSyntheticRulesExerciseEveryRuleKind() {
        let list = PublicSuffixList(datContents: """
        // comment
        com
        *.wild
        !keep.wild
        a.b.c    trailing text after whitespace is ignored
        // ===BEGIN PRIVATE DOMAINS===
        hosted.com
        """)
        XCTAssertEqual(list.ruleCount, 5)
        XCTAssertEqual(list.registrableDomain(forHost: "x.y.wild"), "x.y.wild")
        XCTAssertNil(list.registrableDomain(forHost: "y.wild"))
        XCTAssertEqual(list.registrableDomain(forHost: "z.keep.wild"), "keep.wild")
        XCTAssertEqual(list.registrableDomain(forHost: "q.a.b.c"), "q.a.b.c")
        XCTAssertEqual(list.registrableDomain(forHost: "b.c"), "b.c")          // implicit "*": c is the suffix
        XCTAssertEqual(list.registrableDomain(forHost: "me.hosted.com"), "me.hosted.com")

        let icann = PublicSuffixList(datContents: "com\n// ===BEGIN PRIVATE DOMAINS===\nhosted.com\n",
                                     includePrivateDomains: false)
        XCTAssertEqual(icann.ruleCount, 1)
        XCTAssertEqual(icann.registrableDomain(forHost: "me.hosted.com"), "hosted.com")
    }

    func testPrivateSectionCountsByDefault() throws {
        let list = try psl()
        XCTAssertEqual(list.registrableDomain(forHost: "alice.github.io"), "alice.github.io")
        XCTAssertNil(list.registrableDomain(forHost: "github.io"))
        XCTAssertEqual(list.registrableDomain(forHost: "a.b.blogspot.com"), "b.blogspot.com")
        XCTAssertEqual(list.registrableDomain(forHost: "shop.ravpage.co.il"), "shop.ravpage.co.il")

        let text = try String(contentsOf: XCTUnwrap(PublicSuffixList.bundledURL), encoding: .utf8)
        let icann = PublicSuffixList(datContents: text, includePrivateDomains: false)
        XCTAssertEqual(icann.registrableDomain(forHost: "alice.github.io"), "github.io")
        XCTAssertEqual(icann.registrableDomain(forHost: "www.ynet.co.il"), "ynet.co.il")
    }

    // MARK: - No registrable domain

    func testIPsLocalhostSingleLabelAndInvalidHosts() throws {
        let list = try psl()
        for host in ["192.168.1.1", "127.0.0.1", "::1", "[::1]", "fe80::1", "2001:db8::8a2e:370:7334",
                     "localhost", "intranet", "", ".", ".com", "a..com", "example.com.."] {
            XCTAssertNil(list.registrableDomain(forHost: host), host)
        }
        XCTAssertNil(list.publicSuffix(forHost: "10.0.0.1"))
        // Hosts ending in a number or 0x-hex label are IP-like (URL Standard); a label merely starting "0x" isn't.
        XCTAssertNil(list.registrableDomain(forHost: "0x7f000001"))
        XCTAssertNil(list.registrableDomain(forHost: "a.b.0xff"))
        XCTAssertEqual(list.registrableDomain(forHost: "www.0xfoo.com"), "0xfoo.com")
        XCTAssertEqual(list.registrableDomain(forHost: "a.0x"), "a.0x")
        XCTAssertEqual(list.registrableDomain(forHost: "a.1a"), "a.1a")
    }

    func testKnownTopLevelDomains() throws {
        let list = try psl()
        for tld in ["com", "il", "ai", "uk", "ck", "io", "xn--4dbrk0ce"] { XCTAssertTrue(list.isKnownTopLevelDomain(Substring(tld)), tld) }
        for tld in ["js", "txt", "html", "local", "", "co.il", "5"] { XCTAssertFalse(list.isKnownTopLevelDomain(Substring(tld)), tld) }
    }

    func testIPv4EndsInANumberHasNoFalsePositivesOnRealSuffixes() throws {
        // No PSL rule's last label is numeric or 0x-hex, so "ends in a number" never hides a real host.
        let text = try String(contentsOf: XCTUnwrap(PublicSuffixList.bundledURL), encoding: .utf8)
        text.enumerateLines { line, _ in
            guard !line.hasPrefix("//"), let rule = line.split(separator: " ").first, !rule.isEmpty else { return }
            let host = "a." + String(rule.drop(while: { $0 == "!" || $0 == "*" || $0 == "." }))
            XCTAssertFalse(IPAddress.isIPLiteral(HostNormalizer.normalize(host)), host)
        }
        XCTAssertFalse(IPAddress.isIPLiteral("123.example.com"))
        XCTAssertFalse(IPAddress.isIPLiteral("1password.com"))
        XCTAssertTrue(IPAddress.isDottedQuadIPv4("255.255.255.255"))
        XCTAssertFalse(IPAddress.isDottedQuadIPv4("256.0.0.1"))
        XCTAssertFalse(IPAddress.isDottedQuadIPv4("1.2.3"))
        XCTAssertFalse(IPAddress.isDottedQuadIPv4("1.2.3.4.5"))
    }

    func testEmptyListStillWorksWithImplicitRule() {
        // What a broken bundle would give if it loaded empty text: every TLD is the public suffix.
        let list = PublicSuffixList(datContents: "")
        XCTAssertEqual(list.ruleCount, 0)
        XCTAssertEqual(list.registrableDomain(forHost: "www.ynet.co.il"), "co.il")
        XCTAssertNil(list.registrableDomain(forHost: "com"))
    }

    // MARK: - Speed

    func testLoadTimeIsSmall() throws {
        let text = try String(contentsOf: XCTUnwrap(PublicSuffixList.bundledURL), encoding: .utf8)
        let start = DispatchTime.now().uptimeNanoseconds
        let list = PublicSuffixList(datContents: text)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertGreaterThan(list.ruleCount, 9_000)
        // Generous bound for unoptimized Debug test builds on a busy machine; the app loads it once, lazily.
        XCTAssertLessThan(ms, 500, "PSL parse took \(ms) ms")
    }

    func testTenThousandLookupsStayWellUnderFiftyMilliseconds() throws {
        let list = try psl()
        let bases = ["www.ynet.co.il", "news.bbc.co.uk", "mail.google.com", "a.b.c.d.example.com", "alice.github.io",
                     "x.y.anything.ck", "www.gov.il", "docs.github.com", "192.168.0.1", "localhost",
                     "deep.sub.domain.of.something.co.jp", "xn--9dbne9b.co.il"]
        let hosts = (0..<10_000).map { i in "h\(i % 97)." + bases[i % bases.count] }
        var found = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for h in hosts where list.registrableDomain(forHost: h) != nil { found += 1 }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertGreaterThan(found, 9_000)
        XCTAssertLessThan(ms, 50, "10k lookups took \(ms) ms")
    }
}
