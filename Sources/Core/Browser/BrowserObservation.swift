// P3-6: What one browser read hands to main (001 §14.2, §14.3.6). Only a `SiteAddress` (host + registrable
// domain), the page state and the private flag leave a read; no URL string, no title, no field text.

struct BrowserObservation: Sendable, Equatable {
    /// Where the site came from: for the DEBUG line and `BrowserSupportTracker` only.
    enum Via: Sendable, Equatable {
        case axURL       // AXWebArea.AXURL
        case addressBar  // an unfocused Gecko bar or Safari address field
        case appleEvent  // an opted-in Apple Event (P3-7)
        case kept        // nothing fresh was read: this window's last site (or none) is reported
    }

    /// nil with `.notWebPage`, or with `.unknown`/`.editingAddress` when nothing is kept for the window.
    let site: SiteAddress?
    let pageState: BrowserPageState
    /// nil = unknown (counts as not private, §14.4).
    let isPrivate: Bool?
    let via: Via

    init(site: SiteAddress?, pageState: BrowserPageState, isPrivate: Bool?, via: Via) {
        self.site = site
        self.pageState = pageState
        self.isPrivate = isPrivate
        self.via = via
    }

    /// No window, a timeout, nothing found: keep nothing (or what the caller passes), don't learn.
    static func unknown(kept site: SiteAddress? = nil, isPrivate: Bool? = nil) -> BrowserObservation {
        BrowserObservation(site: site, pageState: .unknown, isPrivate: isPrivate, via: .kept)
    }

    /// The facts main acts on; the AX thread posts only when these change (§14.3.4 "post only on change").
    /// The host counts, not only the site key: a host inside one domain can have a siteHost override (§14.5).
    /// `via` doesn't count.
    func hasSameFacts(as other: BrowserObservation) -> Bool {
        site == other.site && pageState == other.pageState && isPrivate == other.isPrivate
    }
}

/// Why the AX thread wants a read (§14.3.4). `AXValueChanged` from a focused address bar is dropped in the
/// observer callback and never becomes a trigger.
enum BrowserTrigger: Sendable, Equatable {
    case attached              // the browser became frontmost, or its request changed: read at once
    case focusedWindowChanged
    case mainWindowChanged
    case focusedElementChanged
    case titleChanged
    case loadComplete
    case addressValueChanged   // Gecko: AXValueChanged on the unfocused `urlbar-input`
    case wake                  // after sleep or a session switch: read at once
}
