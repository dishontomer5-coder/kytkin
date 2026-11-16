// P3-6: Whether Kytkin watches a browser at all, and how (001 §14.2, §14.4, D11, D12).
// AppController builds a `SitePolicy` from the feature availability and preferences and pushes it to
// ContextMonitor on every relevant change (P3-14); a nil request means "don't attach" (no observer, no timer,
// no AX calls: B15).
//
//   nil when: site rules are unavailable (Kytkin off or no Accessibility) · the bundled Public Suffix List is
//   missing (D11: no registrable domains → site rules off entirely) · the app is Kytkin itself · the app is no
//   browser (not in the catalog and not a web-link handler) · the user turned website rules off (P3-26: one global
//   switch, `browsers.siteRulesOn`, for every browser).
//
// What the request carries for the private-window rules (§14.4): in a window known to be private, rules apply and
// nothing is learned (RuleLearner, as built). With `ignorePrivateWindows` on, the reader also doesn't read the
// address of a detected private window at all (D12), so the browser's app rule applies.

struct BrowserWatchRequest: Sendable, Equatable {
    let engine: BrowserEngine
    let alwaysPrivate: Bool
    /// prefs.browsers.ignorePrivateWindowsCompletely (§14.4).
    let ignorePrivateWindows: Bool
    /// P3-26: set only when "Use Automation" is on (global) AND the browser has a dictionary AND macOS allowed it.
    let appleScript: AppleScriptDialect?
    /// P3-16: which AX private-window probe the reader runs (from the catalog; `.none` for unknown browsers).
    var privateSignal: PrivateWindowSignal = .none
    /// P3-31: how the reader tells the real address bar from the Find box (from the catalog; `.none` = can't tell).
    var addressBarSignal: AddressBarSignal = .none

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
    /// P3-26: the global "Use website rules" (`browsers.siteRulesOn`; an unresolved pre-P3-26 file is decided
    /// against the web-link handlers, as AppController.start() resolves it).
    let siteRulesOn: Bool

    init(availability: FeatureAvailability, browsers: Preferences.Browsers, suffixListLoaded: Bool,
         webLinkHandlers: Set<String>, ownBundleIDPrefix: String) {
        siteRulesAvailable = availability.siteRules
        self.suffixListLoaded = suffixListLoaded
        ignorePrivateWindows = browsers.ignorePrivateWindowsCompletely
        appleEventsBrowsers = availability.appleEventsBrowsers
        self.webLinkHandlers = webLinkHandlers
        self.ownBundleIDPrefix = ownBundleIDPrefix
        siteRulesOn = browsers.siteRulesOn(among: Self.browsers(webLinkHandlers, ownBundleIDPrefix: ownBundleIDPrefix))
    }

    /// P3-26: the browsers an old per-browser file is resolved against: the web-link handlers, Kytkin excluded.
    static func browsers(_ webLinkHandlers: Set<String>, ownBundleIDPrefix: String) -> Set<String> {
        let own = ownBundleIDPrefix.lowercased()
        return webLinkHandlers.filter { !$0.isEmpty && (own.isEmpty || !$0.lowercased().hasPrefix(own)) }
    }

    /// P3-50: why `request(for:)` is nil (an enum-like name for the DEBUG convert trace), nil = it isn't.
    func whyNotWatched(_ bundleID: String) -> String? {
        if !siteRulesAvailable { return "siteRulesUnavailable" }
        if !suffixListLoaded { return "suffixListMissing" }
        if bundleID.isEmpty { return "noApp" }
        if !ownBundleIDPrefix.isEmpty, bundleID.lowercased().hasPrefix(ownBundleIDPrefix.lowercased()) { return "ownApp" }
        if !siteRulesOn { return "websiteRulesOff" }
        if BrowserCatalog.engine(for: bundleID, opensWebLinks: webLinkHandlers.contains(bundleID)) == nil {
            return "notABrowser"
        }
        return nil
    }

    /// nil = don't attach.
    func request(for bundleID: String) -> BrowserWatchRequest? {
        guard siteRulesAvailable, suffixListLoaded, !bundleID.isEmpty else { return nil }
        // Case-insensitive, like ContextAssembler's own-app check (bundle IDs compare without case).
        guard ownBundleIDPrefix.isEmpty || !bundleID.lowercased().hasPrefix(ownBundleIDPrefix.lowercased())
        else { return nil }
        guard siteRulesOn else { return nil }
        guard let engine = BrowserCatalog.engine(for: bundleID, opensWebLinks: webLinkHandlers.contains(bundleID))
        else { return nil }
        let known = BrowserCatalog.known[bundleID]
        let dialect = appleEventsBrowsers.contains(bundleID) ? known?.appleScript : nil
        return BrowserWatchRequest(engine: engine, alwaysPrivate: known?.alwaysPrivate ?? false,
                                   ignorePrivateWindows: ignorePrivateWindows, appleScript: dialect,
                                   privateSignal: known?.privateSignal ?? .none,
                                   addressBarSignal: known?.addressBarSignal ?? .none)
    }
}
