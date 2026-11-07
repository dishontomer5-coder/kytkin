// P3-6: SiteReader (001 §14.3.6, P3-4, D10): http(s) → site; explicit non-web scheme → not a web page; anything it
// can't tell → unreadable. Scheme-less text is accepted only from the Gecko address bar. Plus the DomainExtractor
// helper that tells an explicit scheme from "host:port".

import XCTest

final class SiteReaderTests: XCTestCase {
    private var reader: SiteReader!

    override func setUpWithError() throws {
        reader = SiteReader(extractor: try XCTUnwrap(DomainExtractor.bundled))
    }

    private func site(_ host: String, _ domain: String?) -> SiteRead {
        .site(SiteAddress(host: host, registrableDomain: domain, isWebPage: true))
    }

    private let allSources: [AddressSource] = [.axURL, .geckoAddressBar, .addressField, .appleEvent]

    func testHTTPAddressesFromEverySource() {
        for source in allSources {
            XCTAssertEqual(reader.read("https://www.example.com/a/b?q=1#x", from: source),
                           site("www.example.com", "example.com"), "\(source)")
            XCTAssertEqual(reader.read("http://user:pw@shop.example.co.uk:8080/", from: source),
                           site("shop.example.co.uk", "example.co.uk"), "\(source)")
            XCTAssertEqual(reader.read("  https://example.org  ", from: source), site("example.org", "example.org"))
            XCTAssertEqual(reader.read("http://[::1]:3000/", from: source), site("::1", nil))
        }
    }

    func testSchemelessTextOnlyFromTheGeckoBar() {
        XCTAssertEqual(reader.read("www.example.com/news/1", from: .geckoAddressBar), site("www.example.com", "example.com"))
        XCTAssertEqual(reader.read("localhost:8080/app", from: .geckoAddressBar), site("localhost", nil))
        XCTAssertEqual(reader.read("192.168.1.1", from: .geckoAddressBar), site("192.168.1.1", nil))
        for source in [AddressSource.axURL, .addressField, .appleEvent] {
            XCTAssertEqual(reader.read("www.example.com/news/1", from: source), .unreadable, "\(source)")
            XCTAssertEqual(reader.read("localhost:8080", from: source), .unreadable, "\(source)")
            XCTAssertEqual(reader.read("example.net", from: source), .unreadable, "\(source)")
        }
    }

    func testSearchTermsInTheGeckoBarAreUnreadableNotNotWeb() {
        // D10: Firefox can show search terms in an unfocused bar; they must not look like "no site".
        for text in ["how to bake bread", "node.js", "3.5", "hello", "todo: milk", "note:x", "a@example.com", ""] {
            XCTAssertEqual(reader.read(text, from: .geckoAddressBar), .unreadable, text)
        }
    }

    func testExplicitNonWebSchemes() {
        for url in ["chrome://newtab/", "arc://settings", "about:blank", "about:preferences", "file:///Users/x/a.html",
                    "moz-extension://abc/page.html", "view-source:https://example.com", "data:text/plain,hi",
                    "safari-web-extension://id/x"] {
            XCTAssertEqual(reader.read(url, from: .axURL), .notWebPage, url)
            XCTAssertEqual(reader.read(url, from: .appleEvent), .notWebPage, url)
        }
        for text in ["about:blank", "about:newtab", "chrome://settings", "moz-extension://abc/x", "file:///tmp/a"] {
            XCTAssertEqual(reader.read(text, from: .geckoAddressBar), .notWebPage, text)
        }
    }

    func testAnyNonWebSchemeCountsFromAURLSourceOnly() {
        XCTAssertEqual(reader.read("zen:settings", from: .axURL), .notWebPage)
        XCTAssertEqual(reader.read("mailto:a@example.com", from: .appleEvent), .notWebPage)
        XCTAssertEqual(reader.read("zen:settings", from: .geckoAddressBar), .unreadable)
    }

    func testUnreadableURLs() {
        for source in allSources {
            XCTAssertEqual(reader.read("", from: source), .unreadable)
            XCTAssertEqual(reader.read("   ", from: source), .unreadable)
            XCTAssertEqual(reader.read("https://", from: source), .unreadable)
            XCTAssertEqual(reader.read("https://exa mple.com", from: source), .unreadable)
            XCTAssertEqual(reader.read("http://example.com:abc/", from: source), .unreadable)
        }
    }

    func testExplicitScheme() {
        XCTAssertEqual(DomainExtractor.explicitScheme(of: "HTTPS://example.com"), "https")
        XCTAssertEqual(DomainExtractor.explicitScheme(of: "  about:blank"), "about")
        XCTAssertEqual(DomainExtractor.explicitScheme(of: "chrome://newtab"), "chrome")
        XCTAssertEqual(DomainExtractor.explicitScheme(of: "moz-extension://x"), "moz-extension")
        XCTAssertNil(DomainExtractor.explicitScheme(of: "example.com"))
        XCTAssertNil(DomainExtractor.explicitScheme(of: "localhost:8080"))
        XCTAssertNil(DomainExtractor.explicitScheme(of: "example.com:443/path"))
        XCTAssertNil(DomainExtractor.explicitScheme(of: "[::1]:80"))
        XCTAssertNil(DomainExtractor.explicitScheme(of: ""))
        XCTAssertNil(DomainExtractor.explicitScheme(of: "1http://x"))
        XCTAssertEqual(DomainExtractor.explicitScheme(of: "localhost:abc"), "localhost")
    }
}
