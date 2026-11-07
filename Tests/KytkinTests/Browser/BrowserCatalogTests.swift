// P3-6: The browser catalog (001 §14.3.1, D1).

import XCTest

final class BrowserCatalogTests: XCTestCase {
    func testEnginesForKnownBrowsers() {
        XCTAssertEqual(BrowserCatalog.engine(for: "app.zen-browser.zen", opensWebLinks: false), .gecko)
        XCTAssertEqual(BrowserCatalog.engine(for: "company.thebrowser.Browser", opensWebLinks: false), .chromium)
        XCTAssertEqual(BrowserCatalog.engine(for: "com.google.Chrome", opensWebLinks: false), .chromium)
        XCTAssertEqual(BrowserCatalog.engine(for: "com.apple.Safari", opensWebLinks: false), .webkit)
        XCTAssertEqual(BrowserCatalog.engine(for: "org.mozilla.firefox", opensWebLinks: true), .gecko)
        XCTAssertEqual(BrowserCatalog.engine(for: "com.kagi.kagimacOS", opensWebLinks: false), .webkit)
    }

    func testUnknownAppsAreBrowsersOnlyIfTheyOpenWebLinks() {
        XCTAssertEqual(BrowserCatalog.engine(for: "com.example.NewBrowser", opensWebLinks: true), .unknown)
        XCTAssertNil(BrowserCatalog.engine(for: "com.example.NewBrowser", opensWebLinks: false))
        XCTAssertNil(BrowserCatalog.engine(for: "com.tinyspeck.slackmacgap", opensWebLinks: false))
    }

    func testBundleIDsAreUniqueAndKnownMatchesAll() {
        XCTAssertEqual(BrowserCatalog.known.count, BrowserCatalog.all.count)
        for b in BrowserCatalog.all { XCTAssertEqual(BrowserCatalog.known[b.bundleID], b) }
    }

    func testDialectsMatchEngines() {
        for b in BrowserCatalog.all {
            switch b.engine {
            case .gecko: XCTAssertNil(b.appleScript, b.bundleID)   // no AppleScript dictionary (§14.7)
            case .chromium: XCTAssertNotNil(b.appleScript, b.bundleID)
            case .webkit, .unknown: break
            }
        }
        XCTAssertEqual(BrowserCatalog.known["company.thebrowser.Browser"]?.appleScript, .arc)
        XCTAssertEqual(BrowserCatalog.known["com.google.Chrome"]?.appleScript, .chromium)
        XCTAssertEqual(BrowserCatalog.known["com.apple.Safari"]?.appleScript, .safari)
        XCTAssertNil(BrowserCatalog.known["com.kagi.kagimacOS"]?.appleScript)
    }

    func testOnlyTorIsAlwaysPrivate() {
        XCTAssertEqual(BrowserCatalog.all.filter(\.alwaysPrivate).map(\.bundleID), ["org.torproject.torbrowser"])
    }

    func testVerifiedAreTheR3bBrowsersOnly() {
        // Safari stays unverified until P3-3 item 3.
        XCTAssertEqual(Set(BrowserCatalog.all.filter(\.verified).map(\.bundleID)),
                       ["app.zen-browser.zen", "company.thebrowser.Browser", "com.google.Chrome"])
    }

    func testCatalogCoversEveryEngineFamilyFromTheDesign() {
        let ids = Set(BrowserCatalog.known.keys)
        for id in ["com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary", "org.chromium.Chromium",
                   "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                   "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta",
                   "com.brave.Browser.nightly", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                   "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "org.mozilla.librewolf",
                   "net.waterfox.waterfox", "one.ablaze.floorp", "com.apple.SafariTechnologyPreview"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }
}
