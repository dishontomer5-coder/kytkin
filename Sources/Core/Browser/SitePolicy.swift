// P3-6: Whether Kytkin watches a browser at all, and how (001 §14.2, §14.4, D11, D12).
// AppController builds a `SitePolicy` from the feature availability and preferences and pushes it to
// ContextMonitor on every relevant change (P3-14); a nil request means "don't attach" (no observer, no timer,
// no AX calls: B15).
//
//   nil when: site rules are unavailable (Kytkin off or no Accessibility) · the bundled Public Suffix List is
//   missing (D11: no registrable domains → site rules off entirely) · the app is Kytkin itself · the app is no
//   browser (not in the catalog and not a web-link handler) · the user turned site rules off for that browser.
//
// What the request carries for the private-window rules (§14.4): in a window known to be private, rules apply and
// nothing is learned (RuleLearner, as built). With `ignorePrivateWindows` on, the reader also doesn't read the
// address of a detected private window at all (D12), so the browser's app rule applies.

struct BrowserWatchRequest: Sendable, Equatable {
    let engine: BrowserEngine
    let alwaysPrivate: Bool
    /// prefs.browsers.ignorePrivateWindowsCompletely (§14.4).
    let ignorePrivateWindows: Bool
    /// Set only when the user opted in AND Automation is granted (§14.7).
    let appleScript: AppleScriptDialect?

    /// The window's private flag after the catalog's say: Tor Browser is always private.
    func privateFlag(probed: Bool?) -> Bool? {
        alwaysPrivate ? true : probed
    }

    /// D12: false = skip every address read in this window (it is private and the user ignores private windows).
    /// An unknown flag counts as not private.
    func readsAddress(isPrivate: Bool?) -> Bool {
        !(ignorePrivateWindows && isPrivate == true)
    }
}

struct SitePolicy: Sendable, Equatable {
    let siteRulesAvailable: Bool
    let suffixListLoaded: Bool
    let ignorePrivateWindows: Bool
    let appleEventsBrowsers: Set<String>
    let webLinkHandlers: Set<String>
    let ownBundleIDPrefix: String
    /// Bundle ID → site rules on/off; absent = on (§4.2 `browsers.siteRulesEnabled`).
    let siteRulesEnabled: [String: Bool]

    /// P3-9: `siteRulesEnabled` comes from `browsers.siteRulesEnabled` (§14.2); absent = on.
    init(availability: FeatureAvailability, browsers: Preferences.Browsers, suffixListLoaded: Bool,
         webLinkHandlers: Set<String>, ownBundleIDPrefix: String) {
        siteRulesAvailable = availability.siteRules
        self.suffixListLoaded = suffixListLoaded
        ignorePrivateWindows = browsers.ignorePrivateWindowsCompletely
        appleEventsBrowsers = availability.appleEventsBrowsers
        self.webLinkHandlers = webLinkHandlers
        self.ownBundleIDPrefix = ownBundleIDPrefix
        siteRulesEnabled = browsers.siteRulesEnabled
    }

    /// nil = don't attach.
    func request(for bundleID: String) -> BrowserWatchRequest? {
        guard siteRulesAvailable, suffixListLoaded, !bundleID.isEmpty else { return nil }
        // Case-insensitive, like ContextAssembler's own-app check (bundle IDs compare without case).
        guard ownBundleIDPrefix.isEmpty || !bundleID.lowercased().hasPrefix(ownBundleIDPrefix.lowercased())
        else { return nil }
        guard siteRulesEnabled[bundleID] != false else { return nil }
        guard let engine = BrowserCatalog.engine(for: bundleID, opensWebLinks: webLinkHandlers.contains(bundleID))
        else { return nil }
        let known = BrowserCatalog.known[bundleID]
        let dialect = appleEventsBrowsers.contains(bundleID) ? known?.appleScript : nil
        return BrowserWatchRequest(engine: engine, alwaysPrivate: known?.alwaysPrivate ?? false,
                                   ignorePrivateWindows: ignorePrivateWindows, appleScript: dialect)
    }
}
