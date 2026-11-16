// P3-50 (owner retest 2026-11-16, Gmail in Zen: with nothing selected the box never converted; every trace said
// `siteKnown=false pageState=none`, i.e. Kytkin had no browser read at all for Zen at double-Shift time, so the P3-47 QA
// "unknown site" gate refused the whole-box clipboard convert every time): what the convert itself can tell about the
// page that holds the focused text box, independent of the browser watcher. The live adapter walks from the focused
// element up to its outermost `AXWebArea`, reads that page's `AXURL` and hands it straight to `of(url:)`; only the
// category comes back. The address is reduced inside that one call and dropped (design.md: a browser address is
// reduced to host + domain inside the one function that reads it; here even the host is dropped).
//
// Never logged, never stored; the category alone may go to the DEBUG convert trace.

import Foundation

enum PageCategory: String, Sendable, Equatable {
    /// An http(s) page that is not a whole-document web app: the whole-box clipboard convert may run.
    case ordinary
    /// Google Docs / Sheets, Office web, vscode.dev… (`ReplacementCapabilities.clipboardBlockedHosts`): never.
    case wholeDocument
    /// No page, no address, another scheme, or it couldn't be read: the caller keeps refusing the whole box.
    case unknown
    /// P3-53 QA (Coordinator 2026-11-16): an ordinary page of a webmail app (Gmail, Outlook on the web), where a reply
    /// holds a quoted thread: a whole-box Chromium convert needs its quote search complete (`webmailHosts`).
    case webmail

    /// P3-53 QA: an ordinary page for the clipboard and the Chromium path (a webmail page is one).
    var isOrdinary: Bool { self == .ordinary || self == .webmail }

    /// P3-53 QA: webmail hosts (the host itself or a subdomain of it). Host category only; the host is dropped.
    static let webmailHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com"]

    static func isWebmail(host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return webmailHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The category of one page address. The address and its host are dropped on return.
    static func of(url: String) -> PageCategory {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return .unknown }
        if ReplacementCapabilities.blocksClipboard(bundleID: "", host: host) { return .wholeDocument }
        return isWebmail(host: host) ? .webmail : .ordinary
    }

    /// P3-50 QA: the category of the focused box's page from every `AXWebArea` on the way up (innermost first): each
    /// address (nil = its `AXURL` couldn't be read), and whether the walk reached the top (no parent left).
    ///   - any whole-document web area (Docs in an iframe, an Office doc embedded in a page) → `.wholeDocument`;
    ///   - an unreadable address, or a walk that stopped early (timeout, step or time cap), → `.unknown` (an outer area
    ///     not seen could be a whole-document one);
    ///   - else the outermost http(s) area decides (`.ordinary`); areas of other schemes (`about:blank` iframes, a
    ///     browser's own `chrome://` UI) say nothing. None → `.unknown`.
    /// The addresses are dropped on return.
    static func of(webAreaURLs urls: [String?], reachedTop: Bool) -> PageCategory {
        var sawWeb = false
        var sawWebmail = false   // P3-53 QA: any webmail area makes the page one (it only asks for more care)
        for url in urls {
            guard let url else { return .unknown }
            switch of(url: url) {
            case .wholeDocument: return .wholeDocument
            case .ordinary: sawWeb = true
            case .webmail: sawWeb = true; sawWebmail = true
            case .unknown: continue
            }
        }
        guard reachedTop, sawWeb else { return .unknown }
        return sawWebmail ? .webmail : .ordinary
    }
}
