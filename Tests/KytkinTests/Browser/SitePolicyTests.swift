// P3-6: SitePolicy / BrowserWatchRequest (001 §14.2, §14.4, D11, D12): when no browser is watched, and what the
// request says about private windows and Apple Events.

import XCTest

func browserAvailability(on: Bool = true, siteRules: Bool = true,
                         appleEvents: Set<String> = []) -> FeatureAvailability {
    FeatureAvailability(appSwitching: on, doubleShiftConvert: false, doubleShiftToggleOnly: false, wordBuffer: false,
                        learningWithWords: false, learningByDwell: false, siteRules: on && siteRules,
                        chatRules: false, autoFix: false, appleEventsBrowsers: on ? appleEvents : [])
}

final class SitePolicyTests: XCTestCase {
    private func policy(availability: FeatureAvailability = browserAvailability(), ignorePrivate: Bool = false,
                        suffixListLoaded: Bool = true, handlers: Set<String> = [],
                        siteRulesOn: Bool = true, legacyOff: Set<String> = []) -> SitePolicy {
        var browsers = Preferences.Browsers()
        browsers.ignorePrivateWindowsCompletely = ignorePrivate
        browsers.siteRulesOn = siteRulesOn   // P3-26: one global switch
        browsers.legacySiteRulesOff = legacyOff
        return SitePolicy(availability: availability, browsers: browsers, suffixListLoaded: suffixListLoaded,
                          webLinkHandlers: handlers, ownBundleIDPrefix: "io.github.kytkin.")
    }

    func testKnownBrowsersGetARequest() {
        let p = policy()
        XCTAssertEqual(p.request(for: "app.zen-browser.zen"),
                       BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                           appleScript: nil))
        XCTAssertEqual(p.request(for: "com.google.Chrome")?.engine, .chromium)
        XCTAssertEqual(p.request(for: "com.apple.Safari")?.engine, .webkit)
    }

    func testNoAccessibilityOrKytkinOffMeansNoWatching() {
        XCTAssertNil(policy(availability: browserAvailability(siteRules: false)).request(for: "com.google.Chrome"))
        XCTAssertNil(policy(availability: browserAvailability(on: false)).request(for: "com.google.Chrome"))
    }

    func testMissingSuffixListMeansNoWatching() {
        // D11: no registrable domains → site rules off entirely.
        XCTAssertNil(policy(suffixListLoaded: false).request(for: "app.zen-browser.zen"))
    }

    func testKytkinItselfIsNeverWatched() {
        let p = policy(handlers: ["io.github.kytkin.Kytkin", "io.github.kytkin.Kytkin.dev"])
        XCTAssertNil(p.request(for: "io.github.kytkin.Kytkin"))
        XCTAssertNil(p.request(for: "io.github.kytkin.Kytkin.dev"))
        XCTAssertNil(policy(handlers: ["IO.GitHub.Kytkin.Kytkin"]).request(for: "IO.GitHub.Kytkin.Kytkin"),
                     "case-insensitive, like the assembler (QA)")
    }

    func testWebsiteRulesTurnedOffInSettings() {
        // P3-26: one switch for every browser.
        let p = policy(handlers: ["com.example.NewBrowser"], siteRulesOn: false)
        for id in ["com.google.Chrome", "com.apple.Safari", "app.zen-browser.zen", "com.example.NewBrowser"] {
            XCTAssertNil(p.request(for: id), id)
        }
    }

    func testAnUnresolvedOldFileIsDecidedAgainstTheWebLinkHandlers() {
        // P3-26: on unless every browser here (Kytkin excluded) had website rules off.
        let handlers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "io.github.kytkin.Kytkin"]
        XCTAssertNotNil(policy(handlers: handlers, legacyOff: ["com.google.Chrome"]).request(for: "com.google.Chrome"),
                        "Safari still had them on: on for every browser")
        XCTAssertNil(policy(handlers: handlers, legacyOff: ["com.google.Chrome", "com.apple.Safari"])
            .request(for: "com.apple.Safari"), "every browser had them off")
        XCTAssertNotNil(policy(handlers: [], legacyOff: ["com.google.Chrome"]).request(for: "com.google.Chrome"),
                        "no browser list: on")
    }

    func testOtherAppsOnlyAsWebLinkHandlers() {
        let p = policy(handlers: ["com.example.NewBrowser"])
        XCTAssertEqual(p.request(for: "com.example.NewBrowser")?.engine, .unknown)
        XCTAssertNil(p.request(for: "com.apple.TextEdit"))
        XCTAssertNil(p.request(for: ""))
        XCTAssertNil(policy(handlers: ["com.example.NewBrowser"], siteRulesOn: false)
            .request(for: "com.example.NewBrowser"))
    }

    func testAppleScriptOnlyWhenOptedInAndGranted() {
        let granted: Set<String> = ["com.google.Chrome", "company.thebrowser.Browser", "app.zen-browser.zen",
                                    "com.example.NewBrowser"]
        let p = policy(availability: browserAvailability(appleEvents: granted), handlers: ["com.example.NewBrowser"])
        XCTAssertEqual(p.request(for: "com.google.Chrome")?.appleScript, .chromium)
        XCTAssertEqual(p.request(for: "company.thebrowser.Browser")?.appleScript, .arc)
        XCTAssertNil(p.request(for: "com.apple.Safari")?.appleScript, "not opted in")
        XCTAssertNil(p.request(for: "app.zen-browser.zen")?.appleScript, "Gecko has no dictionary")
        XCTAssertNil(p.request(for: "com.example.NewBrowser")?.appleScript, "unknown browsers have no dialect")
    }

    func testPrivateWindowSettingAndTor() {
        let p = policy(ignorePrivate: true)
        XCTAssertEqual(p.request(for: "com.google.Chrome")?.ignorePrivateWindows, true)
        let tor = p.request(for: "org.torproject.torbrowser")
        XCTAssertEqual(tor?.alwaysPrivate, true)
        XCTAssertEqual(tor?.privateFlag(probed: nil), true)
        XCTAssertEqual(tor?.privateFlag(probed: false), true)
    }

    func testReadsAddressFollowsD12() {
        let ignoring = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: true,
                                           appleScript: nil)
        XCTAssertFalse(ignoring.readsAddress(isPrivate: true))
        XCTAssertTrue(ignoring.readsAddress(isPrivate: false))
        XCTAssertTrue(ignoring.readsAddress(isPrivate: nil), "unknown counts as not private")
        let applying = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                           appleScript: nil)
        XCTAssertTrue(applying.readsAddress(isPrivate: true), "rules apply in private windows; learning is off elsewhere")
        XCTAssertEqual(applying.privateFlag(probed: nil), nil)
        XCTAssertEqual(applying.privateFlag(probed: true), true)
    }
}
