// P3-6: What one browser read hands to main (001 §14.2, §14.3.6). Only a `SiteAddress` (host + registrable
// domain), the page state and the private flag leave a read; no URL string, no title, no field text.

struct BrowserObservation: Sendable, Equatable {
    /// Where the site came from: for the DEBUG line and `BrowserSupportTracker` only.
    enum Via: Sendable, Equatable {
        case axURL       // AXWebArea.AXURL
        case addressBar  // an unfocused Gecko bar or Safari address field
        case appleEvent  // an opted-in Apple Event (P3-7)
        /// P3-25 (Coordinator decision): an Apple Event sent after an AX read failed (a hung browser), so nobody knew
        /// whether the address bar had focus: the site may be half-typed. Applied, never learned.
        case appleEventAfterTimeout
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

    /// P3-14 (P3-20 decision, plan.md P3-11/13 T1): the answer came only from the Gecko address bar, not from a web
    /// area's `AXURL`. Firefox can keep half-typed text in an unfocused bar, so such a site is applied but never
    /// learned. P3-25: the same for an Apple Event sent after an AX timeout (the bar's focus was unknown). Only this
    /// one bit of `via` reaches the Context; never any text.
    var siteNotLearnable: Bool { via == .addressBar || via == .appleEventAfterTimeout }

    /// P3-25: the AX read failed before this Apple Event answer.
    func afterAXTimeout() -> BrowserObservation {
        guard via == .appleEvent else { return self }
        return BrowserObservation(site: site, pageState: pageState, isPrivate: isPrivate, via: .appleEventAfterTimeout)
    }

    /// The facts main acts on; the AX thread posts only when these change (§14.3.4 "post only on change").
    /// The host counts, not only the site key: a host inside one domain can have a siteHost override (§14.5).
    /// `via` doesn't count, except whether the site is learnable (P3-14: bar → `AXURL` on the same site makes the
    /// site learnable, so main must hear about it; P3-25 the same after a timeout).
    func hasSameFacts(as other: BrowserObservation) -> Bool {
        site == other.site && pageState == other.pageState && isPrivate == other.isPrivate
            && siteNotLearnable == other.siteNotLearnable
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
