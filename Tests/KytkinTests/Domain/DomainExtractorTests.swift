// P3-2: DomainExtractor: address-bar strings and URLs → (host, registrable domain, isWebPage), including ports,
// user info, IPs, IDN, scheme-less Firefox-style addresses and non-web schemes; plus the shared normalization
// with RuleEngine (a rule and an extracted host always compare equal).

import XCTest

final class DomainExtractorTests: XCTestCase {
    private func extractor(file: StaticString = #filePath, line: UInt = #line) throws -> DomainExtractor {
        try XCTUnwrap(DomainExtractor.bundled, "public_suffix_list.dat is missing", file: file, line: line)
    }

    private func check(_ url: String, host: String?, domain: String?, web: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try extractor().extract(fromURL: url)
        XCTAssertEqual(got, SiteAddress(host: host, registrableDomain: domain, isWebPage: web), url, file: file, line: line)
    }

    func testOrdinaryURLs() throws {
        try check("https://www.ynet.co.il/news/article/123?x=1#top", host: "www.ynet.co.il", domain: "ynet.co.il")
        try check("http://news.bbc.co.uk", host: "news.bbc.co.uk", domain: "bbc.co.uk")
        try check("HTTPS://Docs.Google.COM./document/d/1", host: "docs.google.com", domain: "google.com")
        try check("https://www.gov.il/he/departments", host: "www.gov.il", domain: "www.gov.il")
        try check("https://idf.il/", host: "idf.il", domain: nil)
        try check("https://alice.github.io/blog", host: "alice.github.io", domain: "alice.github.io")
        try check("  https://claude.ai/new \n", host: "claude.ai", domain: "claude.ai")
    }

    func testPortsAndUserInfoAreDropped() throws {
        try check("https://user:secret@www.ynet.co.il:8443/path", host: "www.ynet.co.il", domain: "ynet.co.il")
        try check("http://a@b@example.com/", host: "example.com", domain: "example.com")
        try check("http://example.com:/", host: "example.com", domain: "example.com")
        try check("http://localhost:3000/app", host: "localhost", domain: nil)
        try check("http://example.com:abc/", host: nil, domain: nil, web: false)
    }

    func testIPAddresses() throws {
        try check("http://192.168.1.1/admin", host: "192.168.1.1", domain: nil)
        try check("http://127.0.0.1:8080", host: "127.0.0.1", domain: nil)
        try check("http://[::1]:8080/", host: "::1", domain: nil)
        try check("https://[2001:DB8::1]/", host: "2001:db8::1", domain: nil)
        try check("http://[::1", host: nil, domain: nil, web: false)
        XCTAssertEqual(try extractor().extract(fromURL: "http://192.168.1.1").siteKey, "192.168.1.1")
    }

    func testIDN() throws {
        try check("https://שלום.co.il/", host: "xn--9dbne9b.co.il", domain: "xn--9dbne9b.co.il")
        try check("https://www.דוגמה.ישראל/דף", host: "www.xn--6dbbec0c.xn--4dbrk0ce", domain: "xn--6dbbec0c.xn--4dbrk0ce")
        try check("https://xn--9dbne9b.co.il", host: "xn--9dbne9b.co.il", domain: "xn--9dbne9b.co.il")
    }

    func testSchemeLessAddressBarText() throws {
        // Firefox-family (Zen) address bars hide "https://".
        try check("ynet.co.il/news", host: "ynet.co.il", domain: "ynet.co.il")
        try check("www.ynet.co.il", host: "www.ynet.co.il", domain: "ynet.co.il")
        try check("ynet.co.il:443/x", host: "ynet.co.il", domain: "ynet.co.il")
        try check("localhost:8080", host: "localhost", domain: nil)
        try check("localhost", host: "localhost", domain: nil)
        try check("10.0.0.1", host: "10.0.0.1", domain: nil)
        // A bare word or a phrase is a search being typed, not an address.
        try check("hello", host: nil, domain: nil, web: false)
        try check("hello world", host: nil, domain: nil, web: false)
        try check("what is ynet.co.il", host: nil, domain: nil, web: false)
    }

    func testSchemeLessSearchTextIsNotASite() throws {
        // QA P3-2: Firefox can show search terms in an unfocused address bar. Text with a dot must not become a
        // site unless its last label is a real TLD (or it's a full IPv4 / localhost / bracketed IPv6).
        for text in ["node.js", "node.js tutorial", "what is 3.5", "3.5", "1.2.3", "readme.txt", "index.html",
                     "e.g", "a@b.com", "me@ynet.co.il", "user:pw@ynet.co.il", "256.1.1.1", "10.0.0", "0x7f.0x1",
                     "v1.2.10", "file.swift:12"] {
            XCTAssertEqual(try extractor().extract(fromURL: text), .notWebPage, text)
        }
        // Still sites: real TLDs (ASCII and IDN), dotted-quad IPv4, bracketed IPv6.
        try check("claude.ai", host: "claude.ai", domain: "claude.ai")
        try check("example.com:8080", host: "example.com", domain: "example.com")
        try check("דוגמה.ישראל/x", host: "xn--6dbbec0c.xn--4dbrk0ce", domain: "xn--6dbbec0c.xn--4dbrk0ce")
        try check("192.168.1.1:8080/admin", host: "192.168.1.1", domain: nil)
        try check("[::1]:3000/", host: "::1", domain: nil)
        // With a scheme the strict check doesn't apply: the browser told us it's a URL.
        try check("http://node.js/", host: "node.js", domain: "node.js")
        try check("http://10.1/", host: "10.1", domain: nil)
    }

    func testAdversarialHostsAreRejectedQuickly() throws {
        let e = try extractor()
        let longLabel = String(repeating: "a", count: 100_000)
        var distinctCJK = ""
        for v in 0x4E00..<(0x4E00 + 20_000) { distinctCJK.unicodeScalars.append(Unicode.Scalar(v)!) }
        let manyLabels = Array(repeating: "ש", count: 50_000).joined(separator: ".")
        let start = DispatchTime.now().uptimeNanoseconds
        for host in [longLabel + ".com", distinctCJK + ".com", manyLabels + ".com",
                     String(repeating: "a.", count: 200) + "com"] {
            XCTAssertEqual(e.extract(fromURL: "https://" + host + "/"), .notWebPage)
            XCTAssertEqual(e.site(forHost: host), .notWebPage)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        XCTAssertLessThan(ms, 2_000, "adversarial hosts took \(ms) ms")
        // Bidi/format controls and U+FFFD (what invalid UTF-16 becomes) make a host invalid, not "xn--…".
        for host in ["\u{202E}lmth.com", "ab\u{200B}c.com", "a\u{FFFD}.com", "a\u{0007}.com", "a\u{E000}.com"] {
            XCTAssertEqual(e.extract(fromURL: "https://" + host + "/"), .notWebPage, host.debugDescription)
        }
        // Lone surrogates from an NSString bridge into U+FFFD; still rejected, no crash.
        let bad = NSString(characters: [0x0061, 0xD800, 0x002E, 0x0063, 0x006F, 0x006D], length: 6) as String
        XCTAssertEqual(e.extract(fromURL: "https://" + bad), .notWebPage)
    }

    func testNonWebSchemesHaveNoSite() throws {
        for url in ["about:blank", "about:preferences", "file:///Users/me/a.html", "chrome://settings",
                    "zen://settings", "moz-extension://abc/page.html", "chrome-extension://abc/x.html",
                    "safari-web-extension://abc/x.html", "view-source:https://ynet.co.il", "data:text/html,hi",
                    "javascript:void(0)", "mailto:a@b.com", "blob:https://ynet.co.il/1234", "ftp://example.com",
                    "arc://newtab", "edge://flags", "", "   ", "https://", "https:///path", "http://.com/",
                    "http://a..b.com/", "http://exa mple.com/", "http://ex*ample.com/"] {
            let got = try extractor().extract(fromURL: url)
            XCTAssertEqual(got, .notWebPage, url)
            XCTAssertNil(got.siteKey, url)
        }
    }

    func testSiteKeyFallsBackToHost() throws {
        let e = try extractor()
        XCTAssertEqual(e.extract(fromURL: "https://www.ynet.co.il").siteKey, "ynet.co.il")
        XCTAssertEqual(e.extract(fromURL: "https://idf.il").siteKey, "idf.il")
        XCTAssertEqual(e.extract(fromURL: "http://intranet.").siteKey, "intranet")
    }

    func testSiteForBareHost() throws {
        let e = try extractor()
        XCTAssertEqual(e.site(forHost: "WWW.Ynet.co.il."),
                       SiteAddress(host: "www.ynet.co.il", registrableDomain: "ynet.co.il", isWebPage: true))
        XCTAssertEqual(e.site(forHost: "[::1]"), SiteAddress(host: "::1", registrableDomain: nil, isWebPage: true))
        XCTAssertEqual(e.site(forHost: ""), .notWebPage)
        XCTAssertEqual(e.site(forHost: "a b"), .notWebPage)
    }

    // MARK: - Same normalization as RuleEngine

    func testExtractedHostMatchesRulesTypedInAnyForm() throws {
        let hebrew = InputSourceID("com.apple.keylayout.Hebrew")
        let abc = InputSourceID("com.apple.keylayout.ABC")
        let rules = [
            Rule(id: UUID(), scope: .site(domain: "שלום.co.il"), inputSource: hebrew, origin: .pinned, updatedAt: Date()),
            Rule(id: UUID(), scope: .siteHost(host: "Docs.Google.com."), inputSource: abc, origin: .pinned, updatedAt: Date()),
        ]
        let engine = RuleEngine(rules: rules)
        let e = try extractor()
        for (url, expected) in [("https://www.שלום.co.il/", hebrew), ("https://docs.google.com/x", abc)] {
            let site = e.extract(fromURL: url)
            let ctx = Context(bundleID: "app.zen-browser.zen", pid: 1, host: site.host, siteDomain: site.siteKey,
                              isPrivateWindow: false, chatKey: nil, generation: 1)
            XCTAssertEqual(engine.resolve(ctx).target, expected, url)
        }
        // And a Unicode rule is found by its Punycode scope (pin checks).
        XCTAssertNotNil(engine.rule(for: .site(domain: "xn--9dbne9b.co.il")))
    }
}
