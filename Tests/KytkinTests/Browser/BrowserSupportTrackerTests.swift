// P3-6: BrowserSupportTracker (001 §14.3.5, §14.8, D15): session-only status per browser.

import XCTest

final class BrowserSupportTrackerTests: XCTestCase {
    private let zen = "app.zen-browser.zen"
    private let request = BrowserWatchRequest(engine: .gecko, alwaysPrivate: false, ignorePrivateWindows: false,
                                              appleScript: nil)
    private let example = SiteAddress(host: "example.com", registrableDomain: "example.com", isWebPage: true)

    private func status(_ t: BrowserSupportTracker, request: BrowserWatchRequest?? = .none,
                        availability: FeatureAvailability = browserAvailability(),
                        suffixListLoaded: Bool = true) -> BrowserSupport {
        t.status(bundleID: zen, request: request ?? self.request, availability: availability,
                 suffixListLoaded: suffixListLoaded)
    }

    func testPreconditionStatuses() {
        let t = BrowserSupportTracker()
        XCTAssertEqual(status(t, availability: browserAvailability(on: false)), .off)
        XCTAssertEqual(status(t, suffixListLoaded: false), .siteDataMissing)
        XCTAssertEqual(status(t, availability: browserAvailability(siteRules: false)), .needsAccessibility)
        XCTAssertEqual(status(t, request: .some(nil)), .off, "site rules off for this browser")
        XCTAssertEqual(status(t), .notSeenYet)
    }

    func testWorksAfterAnAXRead() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL),
                 sawWindow: true)
        XCTAssertEqual(status(t), .works)
        XCTAssertEqual(t.status(bundleID: "com.google.Chrome", request: request, availability: browserAvailability(),
                                suffixListLoaded: true), .notSeenYet, "per browser")
    }

    func testNotWebPageCountsAsWorking() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, BrowserObservation(site: nil, pageState: .notWebPage, isPrivate: nil, via: .addressBar),
                 sawWindow: true)
        XCTAssertEqual(status(t), .works)
    }

    func testWorksWithAutomation() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .appleEvent),
                 sawWindow: true)
        XCTAssertEqual(status(t), .worksWithAutomation)
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL),
                 sawWindow: true)
        XCTAssertEqual(status(t), .works)
    }

    func testCantReadAfterThreeUnknownReadsWithAWindow() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, .unknown(), sawWindow: true)
        t.record(bundleID: zen, .unknown(), sawWindow: false)   // no window: doesn't count
        t.record(bundleID: zen, .unknown(), sawWindow: true)
        XCTAssertEqual(status(t), .notSeenYet)
        t.record(bundleID: zen, .unknown(), sawWindow: true)
        XCTAssertEqual(status(t), .cantRead)
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL),
                 sawWindow: true)
        XCTAssertEqual(status(t), .works)
    }

    func testStreakResetsOnSuccessAndNeverOverridesASuccess() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, .unknown(), sawWindow: true)
        t.record(bundleID: zen, .unknown(), sawWindow: true)
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL),
                 sawWindow: true)
        for _ in 0..<5 { t.record(bundleID: zen, .unknown(kept: example), sawWindow: true) }
        XCTAssertEqual(status(t), .works, "a success this session wins")
    }

    func testEditingAndSkippedPrivateReadsAreNeutral() {
        var t = BrowserSupportTracker()
        for _ in 0..<5 {
            t.record(bundleID: zen, BrowserObservation(site: nil, pageState: .editingAddress, isPrivate: nil, via: .kept),
                     sawWindow: true)
            t.record(bundleID: zen, BrowserObservation(site: nil, pageState: .unknown, isPrivate: true, via: .kept),
                     sawWindow: true)
        }
        XCTAssertEqual(status(t), .notSeenYet)
    }

    func testPreconditionsWinOverRecords() {
        var t = BrowserSupportTracker()
        t.record(bundleID: zen, BrowserObservation(site: example, pageState: .page, isPrivate: nil, via: .axURL),
                 sawWindow: true)
        XCTAssertEqual(status(t, availability: browserAvailability(siteRules: false)), .needsAccessibility)
        XCTAssertEqual(status(t, request: .some(nil)), .off)
    }

    func testANewSessionStartsFresh() {
        // D15: nothing is persisted; a new tracker (a new launch) knows nothing.
        XCTAssertEqual(status(BrowserSupportTracker()), .notSeenYet)
    }
}
