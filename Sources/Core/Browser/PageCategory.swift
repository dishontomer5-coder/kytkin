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

    /// The category of one page address. The address and its host are dropped on return.
    static func of(url: String) -> PageCategory {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty else { return .unknown }
        return ReplacementCapabilities.blocksClipboard(bundleID: "", host: host) ? .wholeDocument : .ordinary
    }
}
