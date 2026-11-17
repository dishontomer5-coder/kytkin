// P3-15: Settings → Browsers & Sites logic (001 §14.8): which browsers are listed (installed catalog + best-effort
// web-link handlers, never Kytkin), each BrowserSupport status in plain words, the Automation slot (none for Gecko),
// the missing-PSL notice, the website-rule count, refresh re-reading the inventory (P3-22), and read-only preferences.
// P3-26: the global switches (website rules, private windows; Automation in BrowsersAutomationWiringTests) and the
// "Browser" dropdown (its choices and its default: last browser in front, else first working, else first).

import XCTest

@MainActor
final class BrowsersSettingsModelTests: XCTestCase {
    private let zen = "app.zen-browser.zen"
    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"
    private let edge = "com.microsoft.edgemac"
    private let other = "com.example.Electronish"

    private var store: PreferencesStore!
    private var inventory = BrowserInventorySnapshot()
    private var inventoryReads = 0
    private var support: [String: BrowserSupport] = [:]
    private var lastFront: String?
    private var sut: BrowsersSettingsModel!

    private func make(_ prefs: Preferences = Preferences(), readOnly: Bool = false, suffixListLoaded: Bool = true) {
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        let names = [zen: "Zen", chrome: "Google Chrome", safari: "Safari", edge: "Microsoft Edge", other: "Electronish",
                     "com.kagi.kagimacOS": "Orion"]
        sut = BrowsersSettingsModel(
            store: store, appName: { names[$0] }, suffixListLoaded: suffixListLoaded,
            ownBundleIDPrefix: "io.github.kytkin.",
            inventory: { [unowned self] in
                self.inventoryReads += 1
                return self.inventory
            },
            support: { [unowned self] in self.support[$0] ?? .notSeenYet },
            lastFrontBrowser: { [unowned self] in self.lastFront })
    }

    private func row(_ id: String) throws -> BrowserRow {
        try XCTUnwrap(sut.rows.first { $0.bundleID == id }, id)
    }

    // MARK: - The list

    func testListsInstalledCatalogBrowsersThenOtherHandlers() {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, safari],
                                             webLinkHandlers: [chrome, other, safari, "io.github.kytkin.Kytkin.dev", ""])
        make()
        sut.refresh()
        // P6-0g (design v2, P1): only real browsers (BrowserCatalog): a terminal that opens links (cmux) isn't one.
        XCTAssertEqual(sut.rows.map(\.name), ["Google Chrome", "Safari", "Zen"],
                       "catalog by name (a catalog handler counts as installed); never other link handlers or Kytkin")
        XCTAssertEqual(sut.rows.map(\.isCatalogued), [true, true, true])
    }

    /// P6-0g: other link handlers aren't listed, but they still count for an old file's "Use website rules".
    func testOtherLinkHandlersStillCountForAnOldFilesSwitch() {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen], webLinkHandlers: [other])
        var prefs = Preferences()
        prefs.browsers.legacySiteRulesOff = [zen]
        make(prefs)
        sut.refresh()
        XCTAssertEqual(sut.rows.map(\.bundleID), [zen])
        XCTAssertTrue(sut.siteRulesOn, "the other handler still had them on")
    }

    /// P6-0g (design v2, P2): one status line per browser, with the one button that fixes it.
    func testOneStatusLinePerBrowser() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome, safari, edge])
        support = [safari: .works, chrome: .worksWithAutomation, zen: .cantRead, edge: .needsAccessibility]
        make()
        sut.refresh()
        XCTAssertEqual(sut.statusLine(for: try row(safari)).text, "Works")
        XCTAssertEqual(sut.statusLine(for: try row(chrome)).text, "Works")
        XCTAssertNil(sut.statusLine(for: try row(chrome)).action)
        XCTAssertEqual(sut.statusLine(for: try row(zen)).text, "Not supported", "Firefox-based: no Automation")
        let edgeLine = sut.statusLine(for: try row(edge))
        XCTAssertEqual(edgeLine.text, "Needs permission")
        XCTAssertEqual(edgeLine.action, .openSetup)
        XCTAssertEqual(edgeLine.actionTitle, "Open Setup")

        support = [edge: .cantRead]
        sut.refresh()
        let off = sut.statusLine(for: try row(edge))
        XCTAssertEqual(off.text, "Needs permission", "Automation could help")
        XCTAssertNil(off.action, "the switch is off: no button, the tooltip says to turn it on")
        XCTAssertTrue(off.help?.contains("Work in more browsers") == true)
        XCTAssertEqual(sut.statusLine(for: try row(safari)).text, "Not checked yet")
    }

    func testFooterLine() {
        var prefs = Preferences()
        prefs.rules = [Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .pinned,
                            updatedAt: Date(timeIntervalSince1970: 0))]
        make(prefs)
        XCTAssertTrue(sut.footerText.hasPrefix("1 website rule is saved."))
        sut.siteRulesOn = false
        XCTAssertEqual(sut.footerText, "Website rules are off, so the settings above are paused. 1 website rule is saved.")
    }

    func testRefreshReadsTheInventoryAgain() {
        make()
        sut.refresh()
        XCTAssertTrue(sut.rows.isEmpty)
        inventory = BrowserInventorySnapshot(installedCatalog: [zen])
        sut.refresh()
        XCTAssertEqual(inventoryReads, 2, "P3-22: every time Settings opens or comes to the front")
        XCTAssertEqual(sut.rows.map(\.bundleID), [zen], "a browser installed since launch shows up")
    }

    func testEngineLines() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome, safari, edge], webLinkHandlers: [other])
        make()
        sut.refresh()
        XCTAssertEqual(try row(zen).engineText, "Firefox-based")
        XCTAssertEqual(try row(chrome).engineText, "Chromium-based")
        XCTAssertEqual(try row(safari).engineText, "Safari-based · not tested yet")
        XCTAssertEqual(try row(edge).engineText, "Chromium-based · not tested yet")
    }

    // MARK: - Status

    func testEachStatusInPlainWords() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        make()
        let cases: [(BrowserSupport, String)] = [
            (.works, "Works"), (.worksWithAutomation, "Works (using Automation)"), (.notSeenYet, "Not checked yet"),
            (.cantRead, "Can’t read this browser"), (.needsAccessibility, "Needs Accessibility"),
            (.siteDataMissing, "Website rules are unavailable"), (.off, "Off"),
        ]
        for (status, text) in cases {
            support[zen] = status
            sut.refresh()
            XCTAssertEqual(try row(zen).support, status)
            XCTAssertEqual(try row(zen).statusText, text, "\(status)")
            XCTAssertEqual(try row(zen).isWorking, status == .works || status == .worksWithAutomation)
            XCTAssertEqual(try row(zen).statusAction, status == .needsAccessibility ? .openPermissions : nil)
        }
        support[zen] = .notSeenYet
        sut.refresh()
        XCTAssertEqual(try row(zen).statusHint, "Open Zen and visit any website.")
    }

    func testCantReadPointsToAutomationOnlyWhereItExists() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        support = [zen: .cantRead, chrome: .cantRead]
        make()
        sut.refresh()
        XCTAssertEqual(try row(chrome).statusHint,
                       "Kytkin can’t see the page address. Turn on \"Use Automation\" above.", "P3-24, P3-26")
        XCTAssertTrue(try XCTUnwrap(row(zen).statusHint).contains("Not supported yet"))
        XCTAssertFalse(try XCTUnwrap(row(zen).statusHint).contains("Automation"))
    }

    func testOffSaysWhy() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        var prefs = Preferences()
        prefs.browsers.siteRulesOn = false
        support = [zen: .off, chrome: .off]
        make(prefs)
        sut.refresh()
        XCTAssertEqual(try row(zen).statusHint, "Website rules are off.", "P3-26: the global switch")
        XCTAssertEqual(try row(chrome).statusHint, "Website rules are off.")
        sut.siteRulesOn = true
        XCTAssertEqual(try row(chrome).statusHint, "Kytkin is off or paused.")
    }

    func testStatusesAreReadAgainOnRefresh() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen])
        make()
        sut.refresh()
        XCTAssertEqual(try row(zen).support, .notSeenYet)
        support[zen] = .works
        sut.refresh()
        XCTAssertEqual(try row(zen).support, .works)
    }

    // MARK: - Automation slot (P3-7)

    func testAutomationSlot() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome, safari, "company.thebrowser.Browser",
                                                                "com.kagi.kagimacOS"],
                                             webLinkHandlers: [other])
        make()
        sut.refresh()
        let off = BrowserAutomationState(status: .off, browserIsRunning: false)
        XCTAssertEqual(try row(chrome).automation, .available(off))
        XCTAssertEqual(try row(safari).automation, .available(off))
        XCTAssertEqual(try row("company.thebrowser.Browser").automation, .available(off))
        XCTAssertNil(try row(zen).automationState)
        XCTAssertNil(try row("com.kagi.kagimacOS").automationState, "Orion: no toggle")
        XCTAssertEqual(try row(zen).automation,
                       .notAvailable("Automation isn’t available for Zen: Firefox-based browsers don’t support it."),
                       "no Automation for Gecko (P3-26: named)")
        XCTAssertEqual(try row("com.kagi.kagimacOS").automation,
                       .notAvailable("Automation isn’t available for Orion."))
    }

    // MARK: - Switches

    func testSiteRulesSwitchIsGlobal() {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        make()
        sut.refresh()
        XCTAssertTrue(sut.siteRulesOn, "on by default")
        sut.siteRulesOn = false
        XCTAssertFalse(store.prefs.browsers.siteRulesOn, "P3-26: one switch for every browser")
        XCTAssertFalse(sut.siteRulesOn)
        sut.siteRulesOn = true
        XCTAssertTrue(store.prefs.browsers.siteRulesOn)
    }

    func testAnOldFilesPerBrowserSwitchesShowAsTheGlobalOne() {
        // P3-26: not resolved yet (AppController.start() normally has): decided against the browsers listed here.
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        var prefs = Preferences()
        prefs.browsers.legacySiteRulesOff = [zen]
        make(prefs)
        sut.refresh()
        XCTAssertTrue(sut.siteRulesOn, "Chrome still had them on")
        prefs.browsers.legacySiteRulesOff = [zen, chrome]
        make(prefs)
        sut.refresh()
        XCTAssertFalse(sut.siteRulesOn, "every listed browser had them off")
        sut.siteRulesOn = true
        XCTAssertEqual(store.prefs.browsers.legacySiteRulesOff, [], "the user’s choice settles the old switches")
        XCTAssertTrue(store.prefs.browsers.siteRulesOn)
    }

    func testPrivateWindowsSwitch() {
        make()
        XCTAssertTrue(sut.ignorePrivateWindows, "P6-0g: on for a new install")
        sut.ignorePrivateWindows = false
        XCTAssertFalse(store.prefs.browsers.ignorePrivateWindowsCompletely)
        sut.ignorePrivateWindows = true
        XCTAssertTrue(store.prefs.browsers.ignorePrivateWindowsCompletely)
        sut.ignorePrivateWindows = false
        XCTAssertFalse(store.prefs.browsers.ignorePrivateWindowsCompletely)
    }

    func testAddressBarSwitch() {
        // P3-29: "Use the browser's language in the address bar", on by default.
        make()
        XCTAssertTrue(sut.browserLanguageInAddressBar)
        sut.browserLanguageInAddressBar = false
        XCTAssertFalse(store.prefs.browsers.browserLanguageInAddressBar)
        sut.browserLanguageInAddressBar = true
        XCTAssertTrue(store.prefs.browsers.browserLanguageInAddressBar)
        XCTAssertEqual(BrowsersSettingsModel.addressBarToggleTitle, "Use the browser’s language in the address bar")
        XCTAssertTrue(BrowsersSettingsModel.addressBarExplanation.contains("English"))
    }

    func testReadOnlyPreferencesChangeNothing() {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen])
        make(readOnly: true)
        sut.refresh()
        XCTAssertFalse(sut.isEditable)
        XCTAssertFalse(sut.notices.isEmpty, "the notice says why")
        sut.siteRulesOn = false
        sut.setUseAutomation(true)
        sut.ignorePrivateWindows = true
        sut.browserLanguageInAddressBar = false   // P3-29
        XCTAssertEqual(store.prefs.browsers, Preferences.Browsers())
    }

    // MARK: - The dropdown (P3-26)

    func testDropdownDefaultsToTheLastBrowserInFront() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome, safari])
        support = [safari: .works]
        lastFront = zen
        make()
        sut.refresh()
        XCTAssertEqual(sut.selectedRow?.bundleID, zen, "the browser most recently in front")
        lastFront = "com.example.NotListed"
        XCTAssertEqual(sut.selectedRow?.bundleID, safari, "unknown last browser: the first working one")
        lastFront = nil
        support = [:]
        sut.refresh()
        XCTAssertEqual(sut.selectedRow?.bundleID, chrome, "none working: the first listed")
    }

    func testDropdownChoiceIsUIStateOnly() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        lastFront = chrome
        make()
        sut.refresh()
        let before = store.prefs
        sut.selectedBrowserID = zen
        XCTAssertEqual(sut.selectedRow?.bundleID, zen, "the user’s choice beats the default")
        XCTAssertEqual(sut.selectedRow?.automation,
                       .notAvailable("Automation isn’t available for Zen: Firefox-based browsers don’t support it."))
        XCTAssertEqual(store.prefs, before, "never stored")
        inventory = BrowserInventorySnapshot(installedCatalog: [chrome])
        sut.refresh()
        XCTAssertEqual(sut.selectedRow?.bundleID, chrome, "a choice that is no longer listed falls back")
    }

    func testDropdownIsEmptyWithoutBrowsers() {
        make()
        sut.refresh()
        XCTAssertNil(sut.selectedRow)
    }

    // MARK: - Texts and counts

    func testMissingSuffixListNotice() {
        make(suffixListLoaded: false)
        XCTAssertEqual(sut.dataMissingNotice, BrowsersSettingsModel.dataMissingText)
        make()
        XCTAssertNil(sut.dataMissingNotice)
    }

    func testWebsiteRuleCount() {
        let at = Date(timeIntervalSince1970: 1_000)
        var prefs = Preferences()
        make(prefs)
        XCTAssertEqual(sut.websiteRuleCountText, "No website rules yet.")
        prefs.rules = [Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned, updatedAt: at)]
        make(prefs)
        XCTAssertEqual(sut.websiteRuleCountText, "1 website rule")
        prefs.rules += [
            Rule(scope: .site(domain: "YNET.co.il."), inputSource: IDs.abc, origin: .learned, updatedAt: at),
            Rule(scope: .siteHost(host: "news.ynet.co.il"), inputSource: IDs.abc, origin: .pinned, updatedAt: at),
            .app("com.apple.Notes", IDs.abc),
        ]
        make(prefs)
        XCTAssertEqual(sut.websiteRuleCount, 2, "a duplicate key counts once; app rules don’t count")
        XCTAssertEqual(sut.websiteRuleCountText, "2 website rules")
    }

    func testTheOwnersNotesAreThere() {
        // P3-30: Safari's private windows by the English title only (the shield button is no signal any more).
        // P6-0c (copy review B-5): one private-window line per browser, in its status.
        let note = { (id: String) in
            BrowsersSettingsModel.privateWindowNote(bundleID: id, engine: BrowserCatalog.known[id]?.engine ?? .unknown)
        }
        XCTAssertTrue(note("com.google.Chrome")?.contains("Chrome is in English or Hebrew") == true)
        XCTAssertTrue(note("company.thebrowser.Browser")?.contains("only with Automation") == true)
        XCTAssertTrue(note("org.torproject.torbrowser")?.contains("every window") == true)
        XCTAssertTrue(note("app.zen-browser.zen")?.contains("can’t tell") == true)
        XCTAssertTrue(note("com.apple.Safari")?.contains("when Safari is in English") == true)
        XCTAssertFalse(note("com.apple.Safari")?.contains("any language") == true)
        // P6-0g (design v2, P2): the review's wording.
        XCTAssertEqual(BrowsersSettingsModel.automationToggleTitle, "Work in more browsers")
        XCTAssertEqual(BrowsersSettingsModel.automationExplanation,
                       "For browsers Kytkin can’t read by itself. macOS asks you once for each browser.")
        XCTAssertTrue(BrowsersSettingsModel.groupingText.contains("news.ynet.co.il"))
        XCTAssertEqual(BrowsersSettingsModel.privateExplanation, "Kytkin doesn’t look at addresses in private windows.")
        XCTAssertEqual(BrowsersSettingsModel.privateToggleTitle, "Ignore private windows")
    }
}

// MARK: - About (P3-15)

final class AboutAcknowledgementsTests: XCTestCase {
    func testPublicSuffixListAcknowledgementWithItsVersion() throws {
        let about = AboutInfo(infoDictionary: [:], suffixListVersion: "2026-11-06_09-01-47_UTC")
        let psl = try XCTUnwrap(about.acknowledgements.first)
        XCTAssertEqual(psl.title, "Public Suffix List")
        XCTAssertEqual(psl.license, "Mozilla Public License 2.0")
        XCTAssertEqual(psl.licenseURL.absoluteString, "https://mozilla.org/MPL/2.0/")
        XCTAssertTrue(psl.detail.hasPrefix("Public Suffix List (publicsuffix.org), used unmodified to group website "
                                           + "addresses into sites."))
        XCTAssertTrue(psl.detail.hasSuffix("Version 2026-11-06."))
        XCTAssertFalse(AboutInfo(infoDictionary: [:]).acknowledgements[0].detail.contains("Version"))
    }

    /// P6-0l: the owner's dedication, word for word, above the third-party credit.
    func testDedication() {
        XCTAssertEqual(AboutInfo.acknowledgementsTitle, "Acknowledgements")
        XCTAssertEqual(AboutInfo.dedication, "Kytkin was built by Tomer Dishon for Ofir W.\n"
                       + "So she would never have to pay for a keyboard switcher again — and get a better one.")
        XCTAssertEqual(AboutInfo.thirdPartyTitle, "Third-party software")
    }

    func testDisplayVersion() {
        XCTAssertEqual(AboutInfo.displayVersion("2026-11-06_09-01-47_UTC"), "2026-11-06")
        XCTAssertEqual(AboutInfo.displayVersion("weird"), "weird")
        XCTAssertEqual(AboutInfo.displayVersion("2026/11/06 x"), "2026/11/06 x")
    }

    func testVersionFromTheListHeader() {
        let header = "// This Source Code Form …\n\n// ===BEGIN ICANN DOMAINS===\n// VERSION: 2026-11-06_09-01-47_UTC\n"
            + "// COMMIT: abc\nac\n"
        XCTAssertEqual(PublicSuffixList.version(inHeader: Substring(header)), "2026-11-06_09-01-47_UTC")
        XCTAssertNil(PublicSuffixList.version(inHeader: "com\nnet\n"))
        XCTAssertNil(PublicSuffixList.version(inHeader: "// VERSION:   \n"))
    }

    func testTheBundledListHasAVersion() {
        XCTAssertNotNil(PublicSuffixList.bundledVersion, "the bundled file keeps its header (shipped unmodified)")
    }

    func testSettingsFolderTarget() {
        let file = URL(fileURLWithPath: "/x/Kytkin/preferences.json")
        let folder = file.deletingLastPathComponent()
        XCTAssertEqual(SettingsFolderTarget.decide(fileURL: file, exists: { _ in true }), .revealFile(file))
        XCTAssertEqual(SettingsFolderTarget.decide(fileURL: file, exists: { $0 == folder }), .openFolder(folder))
        XCTAssertEqual(SettingsFolderTarget.decide(fileURL: file, exists: { _ in false }), .unavailable,
                       "Kytkin never creates the folder just to show it")
    }
}
