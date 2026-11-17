// P6-0g (design v2 review): language names everywhere ("English", "English (ABC)" only in pickers), the Rules table
// with the app exceptions (the Kytkin key, Leave Alone, the Double-Shift checkbox, "+" / "−"), header sorting, short
// dates, the Troubleshooting rows, and the privacy-safe "Copy Diagnostics" text.

import XCTest

@MainActor
final class DesignV2Tests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let term = "com.apple.Terminal"
    private let slack = "com.tinyspeck.slackmacgap"
    private let tNow = Date(timeIntervalSince1970: 9_000)

    private func info(_ id: InputSourceID, _ name: String, _ code: String, enabled: Bool = true) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: code, isEnabled: enabled, isConvertible: true,
                        isInputMethod: false)
    }

    // MARK: - Language names (review P1)

    func testFriendlyNamesComeFromTheLanguage() {
        XCTAssertEqual(LanguageNames.friendly(info(IDs.abc, "ABC", "en")), "English")
        XCTAssertEqual(LanguageNames.friendly(info(IDs.hebrew, "Hebrew", "he")), "Hebrew")
        XCTAssertEqual(LanguageNames.friendly(info(InputSourceID("com.apple.keylayout.Hebrew-QWERTY"), "Hebrew-QWERTY",
                                                   "he")), "Hebrew")
        XCTAssertEqual(LanguageNames.friendly(info(IDs.russian, "Russian - PC", "ru_RU")), "Russian")
        XCTAssertEqual(LanguageNames.friendly(info(IDs.abc, "ABC", "")), "ABC", "no language: the layout's own name")
        XCTAssertEqual(LanguageNames.friendly(info(InputSourceID("user.he-custom"), "My Hebrew", "he")), "My Hebrew",
                       "an imported layout keeps the name its file gives it")
    }

    func testPickersShowTheLayoutToo() {
        XCTAssertEqual(LanguageNames.pickerTitle(info(IDs.abc, "ABC", "en")), "English (ABC)")
        XCTAssertEqual(LanguageNames.pickerTitle(info(IDs.hebrew, "Hebrew", "he")), "Hebrew", "no repeat")
        XCTAssertEqual(LanguageNames.pickerTitle(info(InputSourceID("user.x"), "Mine", "he")), "Mine")
        let options = DefaultBehaviorOption.options(current: .keepCurrent,
                                                    sources: [info(IDs.abc, "ABC", "en"), info(IDs.hebrew, "Hebrew", "he")])
        XCTAssertEqual(options.map(\.title), ["Leave As Is", "Switch to English (ABC)", "Switch to Hebrew"])
    }

    func testLanguageOptionsSayTheLanguageAndTellTwoLayoutsOfOneApart() {
        let us = InputSourceID("com.apple.keylayout.US")
        let sources = [info(IDs.abc, "ABC", "en"), info(IDs.hebrew, "Hebrew", "he")]
        XCTAssertEqual(LanguageOption.options(pair: LanguagePair(a: IDs.abc, b: IDs.hebrew), sources: sources)
            .map(\.name), ["English", "Hebrew"])
        let two = sources + [info(us, "U.S.", "en")]
        XCTAssertEqual(LanguageOption.options(pair: LanguagePair(a: IDs.abc, b: IDs.hebrew), sources: two).map(\.name),
                       ["English (ABC)", "Hebrew", "English (U.S.)"])
    }

    // MARK: - Rules: the app exceptions in the table (review P2)

    private var store: PreferencesStore!
    private var sut: RulesSettingsModel!

    private func make(_ rules: [Rule], apps: [String: Preferences.AppOverride] = [:], readOnly: Bool = false) {
        var prefs = Preferences()
        prefs.rules = rules
        prefs.apps = apps
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        let names = FakeAppNames([notes: "Notes", term: "Terminal", slack: "Slack"])
        sut = RulesSettingsModel(store: store, appName: { names.lookup($0) }, sources: { [unowned self] in
            [self.info(IDs.abc, "ABC", "en"), self.info(IDs.hebrew, "Hebrew", "he"),
             self.info(IDs.russian, "Russian", "ru", enabled: false)]
        }, now: { [tNow] in tNow })
        sut.refresh()
    }

    private func row(_ name: String) -> RuleRow? { sut.rows.first { $0.name == name } }

    func testAppSettingsAreRowsOfTheTable() throws {
        make([Rule.app(notes, IDs.hebrew)], apps: [notes: .init(convertEnabled: false), term: .init(disabled: true),
                                                  slack: .init()])
        sut.sortOrder = .name
        XCTAssertEqual(sut.rows.map(\.name), ["Notes", "Slack", "Terminal"], "one row per app: rule and settings merged")
        let n = try XCTUnwrap(row("Notes"))
        XCTAssertEqual(n.doubleShiftOn, false)
        XCTAssertEqual(n.originTitle, "Learned")
        XCTAssertEqual(n.kindTitle, "App")
        XCTAssertEqual(n.detail, notes, "the bundle ID is the tooltip")
        let t = try XCTUnwrap(row("Terminal"))
        XCTAssertTrue(t.leftAlone)
        XCTAssertEqual(t.languageName, "Leave Alone")
        XCTAssertEqual(t.originTitle, "Always")
        XCTAssertNil(sut.chosenSide(t), "neither half filled")
        let s = try XCTUnwrap(row("Slack"))
        XCTAssertFalse(s.hasRule)
        XCTAssertEqual(s.originTitle, "—")
        XCTAssertEqual(s.dateText(now: tNow), "—")
        XCTAssertEqual(sut.learnedCount, 1, "an app without a rule isn't a learned rule")
        sut.originFilter = .pinned
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal"], "Leave Alone counts as Always")
        sut.originFilter = .learned
        XCTAssertEqual(sut.rows.map(\.name), ["Notes"])
    }

    func testTheKeysHalvesPinTheLanguage() throws {
        make([Rule.app(notes, IDs.hebrew)])
        let n = try XCTUnwrap(row("Notes"))
        XCTAssertEqual(sut.chosenSide(n), .b)
        XCTAssertEqual([sut.letters(.a), sut.letters(.b)], ["EN", "HE"])
        XCTAssertEqual([sut.languageName(.a), sut.languageName(.b)], ["English", "Hebrew"])
        sut.choose(.a, for: n.id)
        XCTAssertEqual(store.prefs.rules.map(\.inputSource), [IDs.abc])
        XCTAssertEqual(store.prefs.rules.map(\.origin), [.pinned], "a choice made here is Always")
    }

    func testTheFilledHalfAgainLeavesTheAppAloneAndKeepsItsRule() throws {
        make([Rule.app(notes, IDs.hebrew, .pinned)])
        sut.choose(.b, for: try XCTUnwrap(row("Notes")).id)
        XCTAssertEqual(store.prefs.apps[notes]?.disabled, true)
        XCTAssertEqual(store.prefs.rules.map(\.inputSource), [IDs.hebrew], "the rule is kept for later")
        let left = try XCTUnwrap(row("Notes"))
        XCTAssertTrue(left.leftAlone)
        XCTAssertNil(sut.chosenSide(left))
        // A half again: back on, with that language.
        sut.choose(.a, for: left.id)
        XCTAssertNil(store.prefs.apps[notes], "the empty settings entry is removed (the rule keeps the row)")
        XCTAssertEqual(store.prefs.rules.map(\.inputSource), [IDs.abc])
    }

    func testTheFilledHalfOfAWebsiteDoesNothing() throws {
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .pinned,
                        updatedAt: Date(timeIntervalSince1970: 1))
        make([site])
        let r = try XCTUnwrap(row("ynet.co.il"))
        XCTAssertNil(r.doubleShiftOn, "Double-Shift is per app")
        sut.choose(.b, for: r.id)
        XCTAssertEqual(store.prefs.rules, [site])
        XCTAssertEqual(store.prefs.apps, [:])
    }

    func testALanguageOutsideThePairIsNamedBesideTheKey() throws {
        make([Rule.app(notes, IDs.russian)])
        let n = try XCTUnwrap(row("Notes"))
        XCTAssertNil(sut.chosenSide(n))
        XCTAssertEqual(sut.otherLanguage(n), "Russian")
    }

    func testTheDoubleShiftCheckboxWritesTheAppSetting() throws {
        make([Rule.app(notes, IDs.hebrew)])
        let n = try XCTUnwrap(row("Notes"))
        XCTAssertEqual(n.doubleShiftOn, true)
        sut.setDoubleShift(false, for: n.id)
        XCTAssertEqual(store.prefs.apps[notes]?.convertEnabled, false, "the same switch as the menu's")
        sut.setDoubleShift(true, for: n.id)
        XCTAssertNil(store.prefs.apps[notes], "back at the default: nothing stored")
    }

    func testAnAppWithoutARuleKeepsItsRowWhenSettingsGoBackToDefault() throws {
        make([], apps: [slack: .init(convertEnabled: false)])
        let s = try XCTUnwrap(row("Slack"))
        sut.setDoubleShift(true, for: s.id)
        XCTAssertEqual(store.prefs.apps[slack], Preferences.AppOverride(), "kept, so the row doesn't vanish")
        XCTAssertEqual(sut.rows.map(\.name), ["Slack"])
        XCTAssertEqual(sut.rows.first?.id, s.id, "a stable id for the selection")
    }

    func testAddAppAndRemove() throws {
        make([Rule.app(notes, IDs.hebrew)], apps: [notes: .init(convertEnabled: false)])
        XCTAssertTrue(sut.addApp(bundleID: " com.apple.Terminal "))
        XCTAssertEqual(store.prefs.apps[term], Preferences.AppOverride())
        XCTAssertNotNil(sut.rowID(forApp: term))
        XCTAssertTrue(sut.addApp(bundleID: notes), "already listed: left as it is")
        XCTAssertFalse(sut.addApp(bundleID: "  "))
        sut.delete(try XCTUnwrap(row("Notes")).id)
        XCTAssertTrue(store.prefs.rules.isEmpty)
        XCTAssertNil(store.prefs.apps[notes], "− removes the rule and the app's settings")
        sut.delete(try XCTUnwrap(row("Terminal")).id)
        XCTAssertNil(store.prefs.apps[term])
        XCTAssertTrue(sut.rows.isEmpty)
    }

    func testTheTextMethodLivesInTheRowsMenu() throws {
        make([Rule.app(notes, IDs.hebrew)])
        let n = try XCTUnwrap(row("Notes"))
        XCTAssertEqual(sut.methodID(for: n), AppMethodOption.defaultID)
        sut.setMethod("keysOnly", for: n)
        XCTAssertEqual(store.prefs.apps[notes]?.replacementMethod, .keysOnly)
    }

    func testReadOnlyBlocksTheNewEdits() throws {
        make([Rule.app(notes, IDs.hebrew)], readOnly: true)
        let n = try XCTUnwrap(row("Notes"))
        sut.choose(.a, for: n.id)
        sut.setDoubleShift(false, for: n.id)
        sut.delete(n.id)
        XCTAssertFalse(sut.addApp(bundleID: term))
        XCTAssertEqual(store.prefs.rules.map(\.inputSource), [IDs.hebrew])
        XCTAssertEqual(store.prefs.apps, [:])
    }

    // MARK: - Sorting by column header (review P1)

    func testAHeaderClickSortsAndASecondReverses() {
        make([Rule.app(notes, IDs.hebrew, at: Date(timeIntervalSince1970: 1)),
              Rule.app(term, IDs.abc, .pinned, at: Date(timeIntervalSince1970: 3)),
              Rule.app(slack, IDs.hebrew, at: Date(timeIntervalSince1970: 2))])
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal", "Slack", "Notes"], "newest first by default")
        sut.sort(by: .name)
        XCTAssertEqual(sut.rows.map(\.name), ["Notes", "Slack", "Terminal"])
        sut.sort(by: .name)
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal", "Slack", "Notes"], "the second click reverses")
        sut.sort(by: .origin)
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal", "Notes", "Slack"], "Always first")
        sut.sort(by: .lastUpdated)
        sut.sort(by: .lastUpdated)
        XCTAssertEqual(sut.rows.map(\.name), ["Notes", "Slack", "Terminal"], "oldest first")
        XCTAssertEqual(RuleSortOrder.allCases.map(\.title), ["App or Website", "Language", "Status", "Last Updated"])
        XCTAssertEqual(RuleOriginFilter.allCases.map(\.title), ["All Rules", "Learned", "Always"])
    }

    // MARK: - Short dates (review P2)

    func testShortDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let now = date(2026, 11, 17, 18, 0)
        XCTAssertEqual(RuleRow.shortDate(date(2026, 11, 17, 15, 28), now: now, calendar: calendar, locale: locale),
                       "Today, 15:28")
        XCTAssertEqual(RuleRow.shortDate(date(2026, 11, 16, 9, 5), now: now, calendar: calendar, locale: locale),
                       "Yesterday, 09:05")
        XCTAssertEqual(RuleRow.shortDate(date(2026, 11, 10, 15, 58), now: now, calendar: calendar, locale: locale),
                       "10 Nov, 15:58")
        XCTAssertEqual(RuleRow.shortDate(date(2025, 11, 10, 15, 58), now: now, calendar: calendar, locale: locale),
                       "10 Nov 2025, 15:58")
    }

    func testTheFooterIsTheReviewsWording() {
        XCTAssertTrue(RulesSettingsModel.pinFooter.hasSuffix("Learned rules follow your latest switch. Always rules "
            + "stay until you change them. Choosing a language here makes the rule Always."))
    }

    // MARK: - Troubleshooting (Advanced)

    func testStatusWordsSplitFromTheDetail() {
        XCTAssertEqual(PermissionsSettingsModel.split("Works: converts text and switches the language.").0, "Works")
        XCTAssertEqual(PermissionsSettingsModel.split("Works: converts text and switches the language.").1,
                       "Converts text and switches the language.")
        XCTAssertEqual(PermissionsSettingsModel.split("Plain").0, "Plain")
        var s = MenuState()
        s.tapMode = .active
        XCTAssertEqual(PermissionsSettingsModel.secureTyping(state: s).status, "Not active")
        XCTAssertEqual(PermissionsSettingsModel.secureTyping(state: s).detail, "No app is blocking Kytkin right now.")
        s.secureInputOn = true
        XCTAssertEqual(PermissionsSettingsModel.secureTyping(state: s).status, "Active")
        s.tapMode = .off
        XCTAssertEqual(PermissionsSettingsModel.secureTyping(state: s).status, "Not checked")
        XCTAssertEqual(PermissionsSettingsModel.secureTypingTitle, "Secure typing")
    }

    // MARK: - Copy Diagnostics (privacy)

    func testDiagnosticsHoldOnlyVersionsStatesAndCounts() {
        var prefs = Preferences()
        prefs.rules = [Rule.app(notes, IDs.hebrew, .pinned),
                       Rule(scope: .site(domain: "secret-bank.example"), inputSource: IDs.hebrew, origin: .learned,
                            updatedAt: Date(timeIntervalSince1970: 1)),
                       Rule(scope: .siteHost(host: "mail.private.example"), inputSource: IDs.abc, origin: .pinned,
                            updatedAt: Date(timeIntervalSince1970: 1)),
                       Rule(scope: .chat(bundleID: slack, key: ChatKey(kind: .id, value: "T1/C9")), inputSource: IDs.abc,
                            origin: .learned, label: "Family", updatedAt: Date(timeIntervalSince1970: 1))]
        prefs.apps = [term: .init(disabled: true), "com.example.Hidden": .init(convertEnabled: false)]
        var state = MenuState()
        state.accessibility = .granted
        state.inputMonitoring = .notDetermined
        state.tapMode = .active
        state.conflicts = Conflicts(runningSwitchers: ["Some Switcher"], perDocumentInputEnabled: false)
        let text = DiagnosticsReport.text(appVersion: "1.0.0 (1)", macOSVersion: "26.1.0", state: state, prefs: prefs,
                                          importedLayoutCount: 2)
        for leak in ["secret-bank", "private.example", "T1/C9", "Family", notes, term, slack, "com.example.Hidden",
                     "Some Switcher"] {
            XCTAssertFalse(text.contains(leak), "never \(leak)")
        }
        for line in ["Kytkin 1.0.0 (1)", "macOS 26.1.0", "Accessibility: allowed", "Input Monitoring: not asked",
                     "Keyboard: active", "Rules: 1 apps, 2 websites (2 always, 2 learned)",
                     "App settings: 2 (1 left alone, 1 without Double-Shift)", "Imported layouts: 2",
                     "Other language switchers running: 1"] {
            XCTAssertTrue(text.contains(line), line)
        }
    }

    // MARK: - General

    func testMenuBarTilesShowEachMode() {
        let store = makeStore(Preferences(), clock: FakeClock())
        let general = GeneralSettingsModel(store: store, loginItems: FakeLoginItems(), sources: { [] },
                                           currentLanguage: { [unowned self] in self.info(IDs.hebrew, "Hebrew", "he") })
        XCTAssertEqual(general.menuBarPreview(for: .iconOnly).letters, nil)
        XCTAssertEqual(general.menuBarPreview(for: .languageOnly).letters, "HE")
        XCTAssertFalse(general.menuBarPreview(for: .languageOnly).showsIcon)
        XCTAssertEqual(general.menuBarPreview(for: .iconAndLanguage).accessibilityLabel, "Kytkin, Hebrew")
        XCTAssertEqual(Preferences.General.MenuBarLabel.allCases.map(GeneralSettingsModel.title(of:)),
                       ["Icon and Language", "Icon Only", "Language Only"])
        XCTAssertEqual(GeneralSettingsModel.enabledTitle, "Kytkin")
    }
}
