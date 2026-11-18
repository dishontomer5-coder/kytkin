// P4-3: the appcast writer behind scripts/make-appcast (Tools/make-appcast/Appcast.swift), with a fake signature.

import XCTest

final class AppcastTests: XCTestCase {
    private let fakeSignature = Data(repeating: 0xAB, count: 64).base64EncodedString()

    private func release(version: String = "1.1.0", build: String = "2", length: Int = 4_242_424,
                         notes: String? = "### What's new\n\n- **One-click updates** <for you> & more.") -> AppcastRelease {
        AppcastRelease(version: version, build: build, length: length, edSignature: fakeSignature,
                       published: Date(timeIntervalSince1970: 1_795_000_000), notesMarkdown: notes)
    }

    private func parse(_ xml: String) throws -> XMLDocument {
        try XMLDocument(xmlString: xml, options: [])
    }

    private func value(_ doc: XMLDocument, _ xpath: String) throws -> String? {
        try doc.nodes(forXPath: xpath).first?.stringValue
    }

    func testOneWellFormedItemWithEverythingSparkleNeeds() throws {
        let doc = try parse(try Appcast.xml(for: release()))
        XCTAssertEqual(try doc.nodes(forXPath: "/rss/channel/item").count, 1)
        let item = "/rss/channel/item"
        XCTAssertEqual(try value(doc, "\(item)/title"), "Kytkin 1.1.0")
        XCTAssertEqual(try value(doc, "\(item)/sparkle:version"), "2")
        XCTAssertEqual(try value(doc, "\(item)/sparkle:shortVersionString"), "1.1.0")
        XCTAssertEqual(try value(doc, "\(item)/sparkle:minimumSystemVersion"), "14.0")
        XCTAssertEqual(try value(doc, "\(item)/sparkle:fullReleaseNotesLink"),
                       "https://github.com/dishontomer5-coder/kytkin/releases/tag/v1.1.0")
        XCTAssertEqual(try value(doc, "\(item)/pubDate"), "Wed, 18 Nov 2026 11:06:40 +0000")
        XCTAssertEqual(try value(doc, "\(item)/enclosure/@url"),
                       "https://github.com/dishontomer5-coder/kytkin/releases/download/v1.1.0/Kytkin-1.1.0.dmg")
        XCTAssertEqual(try value(doc, "\(item)/enclosure/@length"), "4242424")
        XCTAssertEqual(try value(doc, "\(item)/enclosure/@sparkle:edSignature"), fakeSignature)
        XCTAssertEqual(try value(doc, "\(item)/enclosure/@type"), "application/octet-stream")
    }

    func testTheNotesAreEmbeddedAsEscapedMarkdown() throws {
        let xml = try Appcast.xml(for: release())
        XCTAssertTrue(xml.contains("&lt;for you&gt; &amp; more"))
        let doc = try parse(xml)
        XCTAssertEqual(try value(doc, "/rss/channel/item/description"),
                       "### What's new\n\n- **One-click updates** <for you> & more.")
        XCTAssertEqual(try value(doc, "/rss/channel/item/description/@sparkle:format"), "markdown")
        XCTAssertFalse(try Appcast.xml(for: release(notes: nil)).contains("<description sparkle"))
    }

    func testBadInputWritesNothing() {
        XCTAssertNoThrow(try Appcast.xml(for: release(version: "1.1")))
        XCTAssertThrowsError(try Appcast.xml(for: release(version: "v1.1.0")))
        XCTAssertThrowsError(try Appcast.xml(for: release(version: "1.1.0\"><x")))
        XCTAssertThrowsError(try Appcast.xml(for: release(build: "2a")))
        XCTAssertThrowsError(try Appcast.xml(for: release(length: 0)))
        var bad = release()
        bad.edSignature = "not-a-signature"
        XCTAssertThrowsError(try Appcast.xml(for: bad))
    }

    func testSignUpdateOutput() {
        let out = "sparkle:edSignature=\"\(fakeSignature)\" length=\"123456\"\n"
        let parsed = Appcast.parseSignUpdateOutput(out)
        XCTAssertEqual(parsed?.signature, fakeSignature)
        XCTAssertEqual(parsed?.length, 123_456)
        XCTAssertNil(Appcast.parseSignUpdateOutput("error: no key"))
        XCTAssertNil(Appcast.parseSignUpdateOutput("sparkle:edSignature=\"x\" length=\"big\""))
    }

    func testChangelogSection() {
        let changelog = """
            # Changelog

            ## 1.1.0

            ### New
            - Updates.

            ## 1.0.0 (first release)

            - First.
            """
        XCTAssertEqual(Appcast.changelogSection(changelog, version: "1.1.0"), "### New\n- Updates.")
        XCTAssertEqual(Appcast.changelogSection(changelog, version: "1.0.0"), "- First.")
        XCTAssertNil(Appcast.changelogSection(changelog, version: "1.0"))
        XCTAssertNil(Appcast.changelogSection(changelog, version: "2.0.0"))
    }

    func testTheRealChangelogHasThisVersionsSection() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNotNil(Appcast.changelogSection(text, version: "1.1.0"))
    }
}
