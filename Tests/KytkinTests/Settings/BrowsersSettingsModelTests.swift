// P3-15: Settings → Browsers & Sites logic (001 §14.8): which browsers are listed (installed catalog + best-effort
// web-link handlers, never Kytkin), each BrowserSupport status in plain words, the Automation slot (none for Gecko),
// the per-browser switch and the private-window switch (stored only when they differ), the missing-PSL notice, the
// website-rule count, refresh re-reading the inventory (P3-22), and read-only preferences.

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
    private var sut: BrowsersSettingsModel!

    private func make(_ prefs: Preferences = Preferences(), readOnly: Bool = false, suffixListLoaded: Bool = true) {
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        let names = [zen: "Zen", chrome: "Google Chrome", safari: "Safari", edge: "Microsoft Edge", other: "Electronish"]
        sut = BrowsersSettingsModel(
            store: store, appName: { names[$0] }, suffixListLoaded: suffixListLoaded,
            ownBundleIDPrefix: "io.github.kytkin.",
            inventory: { [unowned self] in
                self.inventoryReads += 1
                return self.inventory
            },
            support: { [unowned self] in self.support[$0] ?? .notSeenYet })
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
        XCTAssertEqual(sut.rows.map(\.name), ["Google Chrome", "Safari", "Zen", "Electronish"],
                       "catalog by name (a catalog handler counts as installed), then best effort; never Kytkin")
        XCTAssertEqual(sut.rows.map(\.isCatalogued), [true, true, true, false])
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
        XCTAssertEqual(try row(safari).engineText, "Safari-based · not yet tested")
        XCTAssertEqual(try row(edge).engineText, "Chromium-based · not yet tested")
        XCTAssertEqual(try row(other).engineText, "Other browser (best effort)")
    }

    // MARK: - Status

    func testEachStatusInPlainWords() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        make()
        let cases: [(BrowserSupport, String)] = [
            (.works, "Works"), (.worksWithAutomation, "Works (using Automation)"), (.notSeenYet, "Not checked yet"),
            (.cantRead, "Can't read this browser"), (.needsAccessibility, "Needs Accessibility"),
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
        XCTAssertEqual(try row(zen).statusHint, "Open Zen and visit a website to check.")
    }

    func testCantReadPointsToAutomationOnlyWhereItExists() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        support = [zen: .cantRead, chrome: .cantRead]
        make()
        sut.refresh()
        XCTAssertEqual(try row(chrome).statusHint, "Kytkin can't see the page address. Turn on Automation below.",
                       "P3-24")
        XCTAssertTrue(try XCTUnwrap(row(zen).statusHint).contains("Not supported yet"))
        XCTAssertFalse(try XCTUnwrap(row(zen).statusHint).contains("Automation"))
    }

    func testOffSaysWhy() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen, chrome])
        var prefs = Preferences()
        prefs.browsers.siteRulesEnabled[zen] = false
        support = [zen: .off, chrome: .off]
        make(prefs)
        sut.refresh()
        XCTAssertEqual(try row(zen).statusHint, "Website rules are off.")
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
        XCTAssertEqual(try row(zen).automation, .notAvailable("Automation isn't available for Firefox-based browsers."),
                       "no Automation toggle for Gecko")
        XCTAssertEqual(try row("com.kagi.kagimacOS").automation,
                       .notAvailable("Automation isn't available for this browser."))
        XCTAssertEqual(try row(other).automation, .notAvailable("Automation isn't available for this browser."))
    }

    // MARK: - Switches

    func testSiteRulesSwitchStoresOnlyOff() throws {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen])
        make()
        sut.refresh()
        XCTAssertTrue(try row(zen).siteRulesOn, "absent = on")
        sut.setSiteRulesEnabled(false, for: zen)
        XCTAssertEqual(store.prefs.browsers.siteRulesEnabled, [zen: false])
        XCTAssertFalse(try row(zen).siteRulesOn)
        sut.setSiteRulesEnabled(true, for: zen)
        XCTAssertEqual(store.prefs.browsers.siteRulesEnabled, [:], "on is the default: the entry goes")
        sut.setSiteRulesEnabled(false, for: "")
        XCTAssertEqual(store.prefs.browsers.siteRulesEnabled, [:])
    }

    func testPrivateWindowsSwitch() {
        make()
        XCTAssertFalse(sut.ignorePrivateWindows)
        sut.ignorePrivateWindows = true
        XCTAssertTrue(store.prefs.browsers.ignorePrivateWindowsCompletely)
        sut.ignorePrivateWindows = false
        XCTAssertFalse(store.prefs.browsers.ignorePrivateWindowsCompletely)
    }

    func testReadOnlyPreferencesChangeNothing() {
        inventory = BrowserInventorySnapshot(installedCatalog: [zen])
        make(readOnly: true)
        sut.refresh()
        XCTAssertFalse(sut.isEditable)
        XCTAssertFalse(sut.notices.isEmpty, "the notice says why")
        sut.setSiteRulesEnabled(false, for: zen)
        sut.ignorePrivateWindows = true
        XCTAssertEqual(store.prefs.browsers, Preferences.Browsers())
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
        XCTAssertEqual(sut.websiteRuleCount, 2, "a duplicate key counts once; app rules don't count")
        XCTAssertEqual(sut.websiteRuleCountText, "2 website rules")
    }

    func testTheOwnersNotesAreThere() {
        XCTAssertTrue(BrowsersSettingsModel.safariPrivateNote.contains("Safari"))
        XCTAssertTrue(BrowsersSettingsModel.safariPrivateNote.contains(BrowsersSettingsModel.siteRulesToggleTitle))
        XCTAssertTrue(BrowsersSettingsModel.groupingText.contains("gov.il"))
        XCTAssertTrue(BrowsersSettingsModel.privateExplanation.contains("doesn't read their address"))
        XCTAssertEqual(BrowsersSettingsModel.privateToggleTitle, "Don't use website rules in private windows")
    }
}

// MARK: - About (P3-15)

final class AboutAcknowledgementsTests: XCTestCase {
    func testPublicSuffixListAcknowledgementWithItsVersion() throws {
        let about = AboutInfo(infoDictionary: [:], suffixListVersion: "2026-11-06_09-01-47_UTC")
        let psl = try XCTUnwrap(about.acknowledgements.first)
        XCTAssertEqual(psl.title, "Public Suffix List")
        XCTAssertEqual(psl.license, "Mozilla Public License 2.0 (MPL-2.0)")
        XCTAssertEqual(psl.licenseURL.absoluteString, "https://mozilla.org/MPL/2.0/")
        XCTAssertTrue(psl.detail.hasSuffix("Version 2026-11-06."))
        XCTAssertFalse(AboutInfo(infoDictionary: [:]).acknowledgements[0].detail.contains("Version"))
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
