// P3-14: The apps registered to open https links (001 §14.3.1, D1): browsers outside `BrowserCatalog` get per-website
// memory as "best effort" (owner answer 2). Asks LaunchServices only: no app is launched, activated or messaged, and no
// AX call is made. Read at launch by AppController, and again when Settings opens (P3-22). Kept out of the test target (project.yml lists the
// System/Browser files tests compile one by one), so tests never read the real LaunchServices database.
// Never logs (Browser/ folder, lint rule 2b).

import AppKit

enum BrowserInventory {
    /// Bundle IDs of every app that can open an https link (the catalog's browsers included).
    @MainActor static func webLinkHandlers() -> Set<String> {
        guard let probe = URL(string: "https://example.com") else { return [] }
        return Set(NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// P3-15: the catalog browsers that are installed (LaunchServices knows an app with that bundle ID), for
    /// Settings → Browsers & Sites. A lookup only: nothing is launched.
    @MainActor static func installedCatalogBrowsers() -> Set<String> {
        Set(BrowserCatalog.all.map(\.bundleID).filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        })
    }
}
