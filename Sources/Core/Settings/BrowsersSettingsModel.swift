// P3-15: The logic behind Settings → Browsers & Sites (001 §14.8, D7, D11, D12, D15), so the SwiftUI view stays thin.
//
// - Browsers: every catalog browser that is installed, plus every other app registered for https links ("best
//   effort", owner answer 2). Kytkin itself is never listed. Read by `refresh()` (when Settings opens or comes to the
//   front), which also makes AppController read the web-link handlers again (P3-22: a browser installed since launch).
// - Status per browser: `BrowserSupport` from AppController, this session only (D15), in plain words.
// - "Use website rules" per browser (`browsers.siteRulesEnabled`, absent = on; stored only when off, so the file
//   holds only real differences) and "Don't use website rules in private windows"
//   (`browsers.ignorePrivateWindowsCompletely`; owner meaning: don't read the address, use the browser's own rule, D12).
// - Automation (P3-7): each row says whether an Automation control belongs on it (`BrowserRow.Automation`). P3-7 owns
//   the toggle, the permission state and the click-only prompt; nothing here asks for anything.
// - Missing Public Suffix List (D11): a notice at the top, every status says so, and nothing else changes.
// - No list of website rules here (D7): a count and "Show in Rules".
// - Read-only preferences (§12 S1): every switch is disabled and the setters do nothing.

import Foundation
import Observation

/// What `BrowsersSettingsModel.refresh()` reads (System's `BrowserInventory` in the app, a fake in tests).
struct BrowserInventorySnapshot: Equatable, Sendable {
    /// Catalog browsers that are installed.
    var installedCatalog: Set<String>
    /// Every app registered for https links (catalog browsers included).
    var webLinkHandlers: Set<String>

    init(installedCatalog: Set<String> = [], webLinkHandlers: Set<String> = []) {
        self.installedCatalog = installedCatalog
        self.webLinkHandlers = webLinkHandlers
    }
}

@MainActor @Observable final class BrowsersSettingsModel {
    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let appNames: AppDisplayNames
    @ObservationIgnored private let readInventory: @MainActor () -> BrowserInventorySnapshot
    @ObservationIgnored private let readSupport: @MainActor (String) -> BrowserSupport
    @ObservationIgnored private let ownBundleIDPrefix: String
    let suffixListLoaded: Bool

    /// Read on `refresh()`.
    private(set) var inventory = BrowserInventorySnapshot()
    /// Bumped by `refresh()`, so rows re-read the session's statuses (they aren't observable themselves).
    private(set) var statusGeneration = 0

    init(store: PreferencesStore, appName: @escaping @MainActor (String) -> String?, suffixListLoaded: Bool,
         ownBundleIDPrefix: String, inventory: @escaping @MainActor () -> BrowserInventorySnapshot,
         support: @escaping @MainActor (String) -> BrowserSupport) {
        self.store = store
        self.appNames = AppDisplayNames(lookup: appName)
        self.suffixListLoaded = suffixListLoaded
        self.ownBundleIDPrefix = ownBundleIDPrefix
        self.readInventory = inventory
        self.readSupport = support
    }

    /// When Settings opens or comes to the front.
    func refresh() {
        let next = readInventory()
        if next != inventory { inventory = next }
        statusGeneration += 1
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Texts

    static let dataMissingText = "Website rules are unavailable: a file inside Kytkin is missing. Reinstall Kytkin."
    /// D11: shown at the top of the tab when the bundled Public Suffix List didn't load.
    var dataMissingNotice: String? { suffixListLoaded ? nil : Self.dataMissingText }

    static let introText = "Kytkin can remember a language for each website you visit in these browsers."
    static let siteRulesToggleTitle = "Use website rules"
    static let privateToggleTitle = "Don't use website rules in private windows"
    static let privateExplanation = "Kytkin never remembers websites from private windows. With this on, it also "
        + "doesn't read their address and uses only the browser's own language."
    /// P3-16 replaces this line once the per-browser private-window checks exist (they are waiting for the P3-3 round).
    static let privateDetectionText = "Kytkin can't yet tell which windows are private, except in Tor Browser, where "
        + "every window counts as private. Detection for more browsers comes in a later update."
    /// Owner answer 3 (plan.md §Phase 3): the Safari gap is accepted, with this note.
    static let safariPrivateNote = "Safari doesn't let Kytkin tell when a window is private. If you use Safari's "
        + "private browsing, you can turn off \"\(siteRulesToggleTitle)\" for Safari."
    /// P3-4: how websites are grouped, and why gov.il is different.
    static let groupingText = "A website rule covers the whole site: ynet.co.il also covers www.ynet.co.il and "
        + "news.ynet.co.il. Some addresses are shared by many separate sites, such as gov.il or github.io. There each "
        + "site gets its own rule (www.gov.il, police.gov.il). To use a different language on one part of a site, "
        + "add a subdomain rule in Rules."
    static let noBrowsersText = "No browsers found."

    // MARK: - Rows

    /// Catalog browsers first, then other browsers; each group by name.
    var rows: [BrowserRow] {
        _ = statusGeneration
        let own = ownBundleIDPrefix.lowercased()
        let isOwn = { (id: String) in !own.isEmpty && id.lowercased().hasPrefix(own) }
        let catalog = inventory.installedCatalog
            .union(inventory.webLinkHandlers.filter { BrowserCatalog.known[$0] != nil })
            .filter { !isOwn($0) }
        let others = inventory.webLinkHandlers.filter { BrowserCatalog.known[$0] == nil && !isOwn($0) && !$0.isEmpty }
        let byName = { (a: BrowserRow, b: BrowserRow) in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.bundleID < b.bundleID : c == .orderedAscending
        }
        return catalog.map(row(for:)).sorted(by: byName) + others.map(row(for:)).sorted(by: byName)
    }

    func row(for bundleID: String) -> BrowserRow {
        let known = BrowserCatalog.known[bundleID]
        let name = appNames.name(for: bundleID)
        let support = readSupport(bundleID)
        let on = store.prefs.browsers.siteRulesEnabled[bundleID] != false
        let engine = known?.engine ?? .unknown
        var engineText = Self.engineTitle(engine)
        if let known, !known.verified { engineText += " · not yet tested" }
        let automation: BrowserRow.Automation = if let dialect = known?.appleScript {
            .available(dialect)
        } else if engine == .gecko {
            .notAvailable("Automation isn't available for Firefox-based browsers.")
        } else {
            .notAvailable("Automation isn't available for this browser.")
        }
        let (status, hint, action) = Self.statusTexts(support, name: name, siteRulesOn: on, automation: automation)
        return BrowserRow(bundleID: bundleID, name: name, engineText: engineText, isCatalogued: known != nil,
                          support: support, statusText: status, statusHint: hint, statusAction: action,
                          siteRulesOn: on, automation: automation)
    }

    static func engineTitle(_ engine: BrowserEngine) -> String {
        switch engine {
        case .chromium: "Chromium-based"
        case .gecko: "Firefox-based"
        case .webkit: "Safari-based"
        case .unknown: "Other browser (best effort)"
        }
    }

    /// The status line, an optional hint under it, and the button next to it.
    static func statusTexts(_ support: BrowserSupport, name: String, siteRulesOn: Bool,
                            automation: BrowserRow.Automation)
        -> (String, String?, BrowserRow.StatusAction?) {
        switch support {
        case .works: return ("Works", nil, nil)
        case .worksWithAutomation: return ("Works (using Automation)", nil, nil)
        case .notSeenYet: return ("Not tested yet", "Open \(name) and visit a website to check.", nil)
        case .cantRead:
            if case .available = automation {
                return ("Can't read this browser", "Kytkin can't see the page address. Automation can help.", nil)
            }
            return ("Can't read this browser", "Kytkin can't see the page address here. Not supported yet.", nil)
        case .needsAccessibility:
            return ("Needs Accessibility", "Kytkin needs Accessibility to read the page address.", .openPermissions)
        case .siteDataMissing: return ("Website rules are unavailable", nil, nil)
        case .off:
            return siteRulesOn ? ("Off", "Kytkin is off or paused.", nil) : ("Off", "Website rules are off.", nil)
        }
    }

    // MARK: - Website rules (D7: no second list)

    /// Distinct website and single-address rules.
    var websiteRuleCount: Int {
        Set(store.prefs.rules.compactMap { rule -> RuleScope? in
            guard RuleKindFilter.websites.includes(rule.scope) else { return nil }
            return RuleEngine.normalized(rule.scope)
        }).count
    }

    var websiteRuleCountText: String {
        switch websiteRuleCount {
        case 0: "No website rules yet."
        case 1: "1 website rule"
        case let n: "\(n) website rules"
        }
    }

    // MARK: - Switches

    func siteRulesEnabled(_ bundleID: String) -> Bool {
        store.prefs.browsers.siteRulesEnabled[bundleID] != false
    }

    /// Off is stored as false; on removes the entry (absent = on).
    func setSiteRulesEnabled(_ on: Bool, for bundleID: String) {
        guard isEditable, !bundleID.isEmpty, siteRulesEnabled(bundleID) != on else { return }
        store.update { $0.browsers.siteRulesEnabled[bundleID] = on ? nil : false }
    }

    var ignorePrivateWindows: Bool {
        get { store.prefs.browsers.ignorePrivateWindowsCompletely }
        set {
            guard isEditable, newValue != ignorePrivateWindows else { return }
            store.update { $0.browsers.ignorePrivateWindowsCompletely = newValue }
        }
    }
}
