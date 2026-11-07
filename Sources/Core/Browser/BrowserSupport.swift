// P3-6: "Does Kytkin manage to read this browser?" for Settings → Browsers & Sites (001 §14.2, §14.3.5, §14.8).
// Session only, never persisted (D15; design.md: no capability verdicts on disk): a fresh launch starts every
// browser at `.notSeenYet`. Holds counts per bundle ID, never a site.

enum BrowserSupport: Sendable, Equatable {
    case off                  // Kytkin off, or website rules off for this browser
    case needsAccessibility
    case siteDataMissing      // the bundled Public Suffix List is missing (D11)
    case notSeenYet
    case works
    case worksWithAutomation
    case cantRead
}

struct BrowserSupportTracker: Sendable, Equatable {
    /// `.cantRead` after this many consecutive `.unknown` reads that saw a window, with no success this session.
    static let cantReadAfter = 3

    private struct Record: Sendable, Equatable {
        var readByAX = false
        var readByAppleEvent = false
        var unknownStreak = 0
    }

    private var records: [String: Record] = [:]

    init() {}

    /// After each read of a watched browser.
    mutating func record(bundleID: String, _ o: BrowserObservation, sawWindow: Bool) {
        var r = records[bundleID] ?? Record()
        switch o.pageState {
        case .page, .notWebPage:
            // A fresh answer from the browser (`.kept` can't give these).
            if o.via == .appleEvent { r.readByAppleEvent = true } else { r.readByAX = true }
            r.unknownStreak = 0
        case .unknown:
            // A detected private window that isn't read (D12) says nothing about support.
            if sawWindow && o.isPrivate != true { r.unknownStreak += 1 }
        case .editingAddress:
            break   // the user is typing in the bar: neither a success nor a failure
        }
        records[bundleID] = r
    }

    func status(bundleID: String, request: BrowserWatchRequest?, availability: FeatureAvailability,
                suffixListLoaded: Bool) -> BrowserSupport {
        guard availability.appSwitching else { return .off }          // Kytkin is off
        guard suffixListLoaded else { return .siteDataMissing }
        guard availability.siteRules else { return .needsAccessibility }
        guard request != nil else { return .off }                       // site rules off for this browser
        guard let r = records[bundleID] else { return .notSeenYet }
        if r.readByAX { return .works }
        if r.readByAppleEvent { return .worksWithAutomation }
        return r.unknownStreak >= Self.cantReadAfter ? .cantRead : .notSeenYet
    }
}
