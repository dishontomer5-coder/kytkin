// P3-15: The logic behind Settings → Browsers & Sites (001 §14.8, D7, D11, D12, D15), so the SwiftUI view stays thin.
//
// - Browsers: every catalog browser that is installed, plus every other app registered for https links ("best
//   effort", owner answer 2). Kytkin itself is never listed. Read by `refresh()` (when Settings opens or comes to the
//   front), which also makes AppController read the web-link handlers again (P3-22: a browser installed since launch).
// - P3-26 (plan.md Phase 3 decision 2026-11-08): the tab no longer lists every browser. An "All browsers" section
//   holds the global switches: "Use website rules" (`browsers.siteRulesOn`), "Use Automation when a browser can't be
//   read" (`browsers.useAutomation`; ignored for browsers without a dictionary) and "Don't use website rules in private
//   windows" (`browsers.ignorePrivateWindowsCompletely`; owner meaning: don't read the address, use the browser's own
//   rule, D12). P3-29: also "Use the browser's language in the address bar" (`browsers.browserLanguageInAddressBar`,
//   on by default). Below, a "Browser" dropdown (`rows`) shows ONE browser (`selectedRow`): its status, engine, Automation
//   permission (Ask / Open System Settings, or "not available") and "Open Permissions" where it applies. No
//   per-browser overrides. The choice is UI state only (`selectedBrowserID`, never stored); by default the browser
//   most recently in front this session, else the first working one, else the first.
// - Status per browser: `BrowserSupport` from AppController, this session only (D15), in plain words.
// - Automation (P3-7): the state comes from `AutomationControlling` (AppEnvironment.automation). The switch, "Ask"
//   and "Open System Settings" are user clicks passed straight through (the prompt only from a click); `refresh()`
//   asks for silent checks of the listed browsers that support it while the switch is on (≤ 1 per 5 s each, never a
//   prompt).
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
    /// P3-7: nil = no Automation controller (tests that don't test it): rows show the stored choice, never checked.
    @ObservationIgnored private let automation: (any AutomationControlling)?
    /// P3-26: the browser most recently in front this session (AppController), for the dropdown's default.
    @ObservationIgnored private let lastFrontBrowser: @MainActor () -> String?
    let suffixListLoaded: Bool

    /// Read on `refresh()`.
    private(set) var inventory = BrowserInventorySnapshot()
    /// Bumped by `refresh()`, so rows re-read the session's statuses (they aren't observable themselves).
    private(set) var statusGeneration = 0
    /// P3-26: the dropdown's choice; nil (or a browser no longer listed) = the default. UI state, never stored.
    var selectedBrowserID: String?

    init(store: PreferencesStore, appName: @escaping @MainActor (String) -> String?, suffixListLoaded: Bool,
         ownBundleIDPrefix: String, inventory: @escaping @MainActor () -> BrowserInventorySnapshot,
         support: @escaping @MainActor (String) -> BrowserSupport,
         automation: (any AutomationControlling)? = nil,
         lastFrontBrowser: @escaping @MainActor () -> String? = { nil }) {
        self.store = store
        self.automation = automation
        self.lastFrontBrowser = lastFrontBrowser
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
        runningAppsChanged()
    }

    /// P3-25: an app launched or quit while Settings is open: the Ask button's enablement (and "Open … to check")
    /// follows whether the browser runs, so the rows re-read it, and the silent checks run again.
    func runningAppsChanged() {
        statusGeneration += 1
        // P3-7: silent Automation checks (never a prompt), so a grant or revoke made in System Settings shows here.
        // The controller throttles them (≤ 1 per 5 s each). P3-26: every listed browser that supports Automation,
        // while the global switch is on.
        if let automation, useAutomation {
            let ids = rows.filter { $0.automationState != nil }.map(\.bundleID).sorted()
            if !ids.isEmpty { automation.refreshAutomation(for: ids) }
        }
    }

    var isEditable: Bool { !store.isReadOnly }
    var notices: [SettingsNotice] { SettingsNotice.notices(for: store) }

    // MARK: - Texts

    static let dataMissingText = "Website rules are off because part of Kytkin is missing. Download Kytkin again to "
        + "fix it."   // P6-0c (copy review R-5)
    /// D11: shown at the top of the tab when the bundled Public Suffix List didn't load.
    var dataMissingNotice: String? { suffixListLoaded ? nil : Self.dataMissingText }

    static let introText = "Kytkin can remember a language for each website you visit in your browsers."
    /// P3-26: the section with the global switches.
    static let allBrowsersTitle = "All browsers"
    static let siteRulesToggleTitle = "Use website rules"
    /// P3-26: the one note for the global switches (e.g. Automation for Zen).
    static let skipNote = "Some browsers don't support every option; Kytkin skips what a browser can't do."
    static let browserPickerTitle = "Browser"
    static let privateToggleTitle = "Don't use website rules in private windows"
    static let privateExplanation = "Kytkin never learns from private windows. With this on, it doesn't look at "
        + "their address at all."   // P6-0c (copy review B-4)
    /// P3-16: what the private-window checks can tell, per browser (001 §14.4; owner probe 2026-11-08).
    static let privateDetectionText = "Kytkin recognizes private windows in Chrome when Chrome is in English or "
        + "Hebrew (in any language with Automation), and in Arc only with Automation. Tor Browser's windows always "
        + "count as private. Kytkin can't tell yet in Zen and other Firefox-based browsers."
    /// Owner answer 3 accepted a Safari gap. P3-30: Safari's private windows are recognized only by the English title
    /// (the privacy button also shows in normal windows when it's added to the toolbar).
    static let safariPrivateNote = "In Safari, Kytkin recognizes private windows only when Safari is in English."
    /// P3-4: how websites are grouped, and why gov.il is different.
    /// P6-0c (copy review B-6): the gov.il / github.io detail is where it matters (the Add Website sheet, R-9).
    static let groupingText = "A website rule covers the whole website: ynet.co.il also covers news.ynet.co.il. "
        + "To use a different language on one part, add it in Rules."

    /// P6-0c (copy review B-5): the private-window line for one browser, shown in its status (one sentence for five
    /// browsers was hard to scan). nil = nothing to say.
    static func privateWindowNote(bundleID: String, engine: BrowserEngine) -> String? {
        let known = BrowserCatalog.known[bundleID]
        if known?.alwaysPrivate == true { return "Private windows: every window counts as private." }
        if bundleID.hasPrefix("com.google.Chrome") {
            return "Private windows: recognized when Chrome is in English or Hebrew (any language with Automation)."
        }
        if known?.appleScript == .arc { return "Private windows: recognized only with Automation." }
        if known?.privateSignal == .safari { return "Private windows: recognized when Safari is in English." }
        if engine == .gecko { return "Kytkin can't tell private windows apart yet." }
        return nil
    }
    static let noBrowsersText = "No browsers found."

    // MARK: - Rows (P3-26: the dropdown's choices)

    /// The browsers in the dropdown, unordered: catalog browsers installed, plus every web-link handler. Not Kytkin.
    private var listedBrowserIDs: Set<String> {
        let own = ownBundleIDPrefix.lowercased()
        let isOwn = { (id: String) in !own.isEmpty && id.lowercased().hasPrefix(own) }
        return inventory.installedCatalog.union(inventory.webLinkHandlers).filter { !isOwn($0) && !$0.isEmpty }
    }

    /// Catalog browsers first, then other browsers; each group by name.
    var rows: [BrowserRow] {
        _ = statusGeneration
        let ids = listedBrowserIDs
        let catalog = ids.filter { BrowserCatalog.known[$0] != nil }
        let others = ids.filter { BrowserCatalog.known[$0] == nil }
        let byName = { (a: BrowserRow, b: BrowserRow) in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.bundleID < b.bundleID : c == .orderedAscending
        }
        let on = siteRulesOn
        return catalog.map { row(for: $0, siteRulesOn: on) }.sorted(by: byName)
            + others.map { row(for: $0, siteRulesOn: on) }.sorted(by: byName)
    }

    func row(for bundleID: String) -> BrowserRow {
        row(for: bundleID, siteRulesOn: siteRulesOn)
    }

    private func row(for bundleID: String, siteRulesOn on: Bool) -> BrowserRow {
        let known = BrowserCatalog.known[bundleID]
        let name = appNames.name(for: bundleID)
        let support = readSupport(bundleID)
        let engine = known?.engine ?? .unknown
        var engineText = Self.engineTitle(engine)
        // P6-0c (visual review B1, copy B-9): never next to a live "Works".
        if let known, !known.verified, support != .works, support != .worksWithAutomation {
            engineText += " · not tested yet"
        }
        let automation: BrowserRow.Automation = if known?.appleScript != nil {
            .available(automationState(for: bundleID))
        } else if engine == .gecko {
            .notAvailable("Automation isn't available for \(name): Firefox-based browsers don't support it.")
        } else {
            .notAvailable("Automation isn't available for \(name).")
        }
        let (status, hint, action) = Self.statusTexts(support, name: name, siteRulesOn: on, automation: automation)
        return BrowserRow(bundleID: bundleID, name: name, engineText: engineText, isCatalogued: known != nil,
                          support: support, statusText: status, statusHint: hint, statusAction: action,
                          automation: automation,
                          privateNote: Self.privateWindowNote(bundleID: bundleID, engine: engine))
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
        case .notSeenYet: return ("Not checked yet", "Open \(name) and visit any website.", nil)   // P6-0c (B-7)
        case .cantRead:
            // P3-24: point to Automation when the browser supports it. P3-26: the switch is above (global); the
            // permission (Ask / Open System Settings) is below, next to this status.
            if case .available(let state) = automation {
                let hint = switch state.status {
                case .allowed: "Kytkin can't see the page address, even with Automation."
                case .denied, .notAsked, .checking: "Kytkin can't see the page address. Allow Automation below."
                default: "Kytkin can't see the page address. Turn on \"Use Automation\" above."
                }
                return ("Can't read this browser", hint, nil)
            }
            return ("Can't read this browser", "Kytkin can't see the page address here. Not supported yet.", nil)
        case .needsAccessibility:
            return ("Needs Accessibility", "Kytkin needs Accessibility to read the page address.", .openPermissions)
        case .siteDataMissing: return ("Website rules are unavailable", nil, nil)
        case .off:
            return siteRulesOn ? ("Off", "Kytkin is off or paused.", nil) : ("Off", "Website rules are off.", nil)
        }
    }

    // MARK: - The dropdown (P3-26)

    /// The dropdown's browser: the user's choice while it is listed, else the browser most recently in front (if
    /// listed), else the first working one, else the first. nil only when no browser is listed.
    var selectedRow: BrowserRow? {
        let rows = rows
        if let id = selectedBrowserID, let row = rows.first(where: { $0.bundleID == id }) { return row }
        if let id = lastFrontBrowser(), let row = rows.first(where: { $0.bundleID == id }) { return row }
        return rows.first(where: \.isWorking) ?? rows.first
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

    // MARK: - Switches (P3-26: global)

    /// "Use website rules", for every browser. An old file's per-browser switches are decided against the browsers
    /// listed here until AppController.start() has settled them (normally already done).
    var siteRulesOn: Bool {
        get { store.prefs.browsers.siteRulesOn(among: listedBrowserIDs) }
        set {
            guard isEditable, newValue != siteRulesOn else { return }
            store.update { $0.browsers.setSiteRulesOn(newValue) }
        }
    }

    var ignorePrivateWindows: Bool {
        get { store.prefs.browsers.ignorePrivateWindowsCompletely }
        set {
            guard isEditable, newValue != ignorePrivateWindows else { return }
            store.update { $0.browsers.ignorePrivateWindowsCompletely = newValue }
        }
    }

    // MARK: - Address bar (P3-29, plan.md decision 2026-11-08)

    static let addressBarToggleTitle = "Use the browser's language in the address bar"
    static let addressBarExplanation = "In the address bar, Kytkin uses the browser's language (English unless you "
        + "set one). On web pages, it uses the website's language."   // P6-0c (B-3)

    /// P3-29: `browsers.browserLanguageInAddressBar` (on by default).
    var browserLanguageInAddressBar: Bool {
        get { store.prefs.browsers.browserLanguageInAddressBar }
        set {
            guard isEditable, newValue != browserLanguageInAddressBar else { return }
            store.update { $0.browsers.browserLanguageInAddressBar = newValue }
        }
    }

    // MARK: - Automation (P3-7, 001 §14.7–14.8; P3-26: one global switch)

    // P6-0c (copy review B-1, B-2).
    static let automationToggleTitle = "Ask the browser for the page address (Automation)"
    static let automationExplanation = "Only for browsers Kytkin can't read by itself. macOS asks you once for each "
        + "browser."

    /// The global "Use Automation" (`browsers.useAutomation`).
    var useAutomation: Bool { store.prefs.browsers.useAutomation }

    /// User click only (the global switch). On asks macOS for the running browsers that support it and aren't
    /// allowed yet, one at a time (AutomationControlling); off only stores the choice.
    func setUseAutomation(_ on: Bool) {
        guard isEditable, useAutomation != on else { return }   // a repeated set never asks again
        automation?.setUseAutomation(on)
    }

    /// A browser's Automation state; without a controller, the stored choice only (never checked).
    func automationState(for bundleID: String) -> BrowserAutomationState {
        if let automation { return automation.automationState(for: bundleID) }
        return BrowserAutomationState.make(bundleID: bundleID, optedIn: useAutomation,
                                           permission: nil, browserIsRunning: false)
    }

    /// User click only (the dropdown's "Ask" button).
    func askAutomation(for bundleID: String) {
        let state = automationState(for: bundleID)
        guard state.action == .ask, state.actionEnabled else { return }
        automation?.askAutomation(for: bundleID)
    }

    /// User click only (the dropdown's "Open System Settings" button).
    func openAutomationSettings() {
        automation?.openAutomationSettings()
    }
}
