// P2-22: MenuModel and MenuWarning (001 §5.1, §6.2, §12.1 S1): every line of the menu-bar menu, its text, enabled and
// checked state, order, the "Open Settings…" hook gating, the DEBUG lines, and the label (P2-52 item 4).
// P6-0c: the context block, Turn Kytkin On, one ⚠ line per warning, Title Case, and the label's looks and modes.

import XCTest

@MainActor
final class MenuModelTests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let names = ["com.apple.Notes": "Notes", "com.tinyspeck.slackmacgap": "Slack"]
    private let sourceNames = [IDs.abc: "English", IDs.hebrew: "Hebrew"]   // P6-0g: language names

    private func source(_ id: InputSourceID) -> InputSourceInfo {
        InputSourceInfo(id: id, name: sourceNames[id] ?? id.rawValue, languageCode: id == IDs.hebrew ? "he" : "en",
                        isEnabled: true, isConvertible: true, isInputMethod: false)
    }

    private func rule(matched: Rule? = nil, level: Resolution.Level = .app, target: InputSourceID? = nil,
                      pinScope: RuleScope? = nil) -> SwitchController.CurrentRule {
        SwitchController.CurrentRule(
            context: Context(bundleID: notes, pid: 10, generation: 1),
            resolution: Resolution(target: target ?? matched?.inputSource, matched: matched,
                                   level: matched == nil && level == .app ? .none : level),
            pinScope: pinScope ?? .app(bundleID: notes))
    }

    private func items(_ state: MenuState, current: InputSourceID? = IDs.abc, settings: Bool = false,
                       debug: Bool = false) -> [MenuItemModel] {
        MenuModel.items(state: state, currentSource: current.map(source),
                        settingsAvailable: settings, includeDebug: debug,
                        sourceName: { self.sourceNames[$0] ?? $0.rawValue },
                        appName: { self.names[$0] ?? $0 })
    }

    private func titles(_ items: [MenuItemModel]) -> [String] {
        items.map { $0.kind == .separator ? "—" : $0.title }
    }

    private func item(_ title: String, in items: [MenuItemModel], file: StaticString = #filePath,
                      line: UInt = #line) -> MenuItemModel? {
        let found = items.first { $0.title == title }
        if found == nil { XCTFail("no item \"\(title)\" in \(titles(items))", file: file, line: line) }
        return found
    }

    /// The line each warning adds (P6-0c: one per warning; "Kytkin is turned off" is the menu's first line instead).
    private func warningLines(_ state: MenuState, settings: Bool = false) -> [MenuItemModel] {
        MenuWarning.list(for: state).filter { $0 != .kytkinOff }
            .map { MenuModel.item(for: $0, settingsAvailable: settings) }
    }

    private let warn = MenuItemModel.warningSymbol

    // MARK: - Whole layout (P6-0c: visual review §3.3)

    func testQuietMenuLayout() {
        XCTAssertEqual(items(MenuState()), [
            .action("Pause Kytkin", .togglePause),
            .action("Settings…", .openSettings(.general), enabled: false, key: ","),
            .separator,
            .action("Quit Kytkin", .quit, key: "q"),
        ], "no app yet: no context block (copy review M-3)")
    }

    func testFullLayoutWithRuleSettingsAndAWarning() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        s.secureInputOn = true
        s.pairInputSources = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        XCTAssertEqual(titles(items(s, settings: true)), [
            "In Notes",
            "Always use",
            "Follow My Last Switch",
            "—",
            "Turn Off Double-Shift in Notes",
            "Forget Rule for Notes",
            "—",
            "Double-Shift waits: another app is protecting your typing",
            "—",
            "Pause Kytkin",
            "Settings…",
            "—",
            "Quit Kytkin",
        ])
        let all = items(s, settings: true)
        XCTAssertEqual(all[0].kind, .header)
        XCTAssertEqual(item("Settings…", in: all)?.isEnabled, true)
        XCTAssertEqual(item("Settings…", in: all)?.keyEquivalent, ",")
        XCTAssertFalse(titles(all).contains("About Kytkin"), "P6-0f: About is a Settings tab")
        XCTAssertEqual(all[1...5].map(\.indent), [0, 0, 0, 0, 0], "P6-0g (review P3): one left inset for every item")
        XCTAssertEqual(item("Quit Kytkin", in: all)?.keyEquivalent, "q")
    }

    /// P6-0c (visual review N2, copy M-10): turned off → "Turn Kytkin On" first; no context block, no Pause.
    func testTurnedOffOffersTurnOnFirst() {
        var s = MenuState()
        s.enabled = false
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        let all = items(s, settings: true)
        XCTAssertEqual(all[0], .action("Turn Kytkin On", .turnOn))
        XCTAssertFalse(titles(all).contains("Pause Kytkin"))
        XCTAssertFalse(titles(all).contains { $0.hasPrefix("Notes") || $0.hasPrefix("Always") })
        XCTAssertEqual(titles(all).filter { $0 == "Turn Kytkin On" }.count, 1, "not again as a warning")
        XCTAssertEqual(titles(all), ["Turn Kytkin On", "—", "Settings…", "—", "Quit Kytkin"])
    }

    /// P6-0f: the update line sits with the warnings, above Pause and Settings.
    func testUpdateLineSitsWithTheWarnings() {
        var s = MenuState()
        s.secureInputOn = true
        s.updateNotice = UpdateNotice(version: "9.0.0")
        XCTAssertEqual(titles(items(s, settings: true)), [
            "Double-Shift waits: another app is protecting your typing",
            "Update available: Kytkin 9.0.0…",
            "—",
            "Pause Kytkin",
            "Settings…",
            "—",
            "Quit Kytkin",
        ])
    }

    func testDebugLinesComeBeforeQuit() {
        var s = MenuState()
        s.tapMode = .listenOnly
        s.degradedByWatchdog = true
        s.doubleShiftCount = 3
        s.tapReEnableCount = 2
        s.slowCallbackCount = 4
        let all = items(s, debug: true)
        XCTAssertEqual(Array(titles(all).suffix(3)), ["—", "Debug", "Quit Kytkin"], "P6-0f: one submenu above Quit")
        let lines = debugLines(all)
        XCTAssertEqual(titles(lines), [
            "Keyboard: listenOnly (lowered)",
            "Double-Shift count: 3",
            "Tap re-enables: 2",
            "Slow key callbacks (over 1 ms): 4",
            "Switch to",
        ])
        XCTAssertEqual(item("Switch to", in: lines)?.kind, .debugSwitchSubmenu)
        XCTAssertFalse(titles(items(s)).contains("Debug"), "Release: no Debug submenu")
    }

    /// The lines inside "Debug ▸" (P6-0f).
    private func debugLines(_ all: [MenuItemModel]) -> [MenuItemModel] {
        for i in all { if case .submenu(let lines) = i.kind, i.title == "Debug" { return lines } }
        XCTFail("no Debug submenu in \(titles(all))")
        return []
    }

    /// P2-55: the learner line sits with the other DEBUG lines, Debug builds only.
    func testLearnerDebugLineIsShownOnlyInDebug() {
        var s = MenuState()
        s.learnerDebug = "Learner: idle (words)"
        let t = titles(debugLines(items(s, debug: true)))
        XCTAssertEqual(Array(t.suffix(2)), ["Learner: idle (words)", "Switch to"])
        XCTAssertFalse(titles(items(s)).contains { $0.contains("Learner") }, "Release: no learner line")
    }

    // MARK: - Context block, Pin, Forget, Don't Convert (P6-0c: flows S2, S3; visual N3–N5)

    private func context(_ s: MenuState, current: InputSourceID? = IDs.abc) -> [MenuItemModel] {
        MenuModel.contextItems(state: s, currentSource: current.map(source),
                               sourceName: { self.sourceNames[$0] ?? $0.rawValue }, appName: { self.names[$0] ?? $0 })
    }

    // P6-0g (design v2, lg-menu): "In <App>", "Always use" with the Kytkin key, "Follow My Last Switch", then
    // "Turn Off Double-Shift in <App>" and "Forget Rule for <App>". One left inset (no indent).

    private let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
    private let codes = [IDs.abc: "EN", IDs.hebrew: "HE"]

    private func keyed(_ s: MenuState, current: InputSourceID? = IDs.abc) -> [MenuItemModel] {
        var s = s
        s.pairInputSources = pair
        return MenuModel.contextItems(state: s, currentSource: current.map(source),
                                      sourceName: { self.sourceNames[$0] ?? $0.rawValue },
                                      sourceCode: { self.codes[$0] }, appName: { self.names[$0] ?? $0 })
    }

    private func key(_ chosen: PairSide?) -> MenuItemModel.LanguageKey {
        MenuItemModel.LanguageKey(a: .init(letters: "EN", name: "English", source: IDs.abc),
                                  b: .init(letters: "HE", name: "Hebrew", source: IDs.hebrew), chosen: chosen)
    }

    /// P6-0g QA: the keyboard fallback for the custom key view (Return on the highlighted line).
    func testReturnOnTheKeyPinsALanguage() {
        XCTAssertEqual(key(nil).keyboardAction(current: IDs.hebrew), .pinCurrentTo(IDs.hebrew))
        XCTAssertEqual(key(nil).keyboardAction(current: IDs.abc), .pinCurrentTo(IDs.abc))
        XCTAssertEqual(key(nil).keyboardAction(current: IDs.russian), .pinCurrentTo(IDs.abc))
        XCTAssertEqual(key(nil).keyboardAction(current: nil), .pinCurrentTo(IDs.abc))
        XCTAssertEqual(key(.a).keyboardAction(current: IDs.abc), .pinCurrentTo(IDs.hebrew), "pinned: the other half")
        XCTAssertEqual(key(.b).keyboardAction(current: IDs.hebrew), .pinCurrentTo(IDs.abc))
    }

    func testLearnedRule() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        XCTAssertEqual(keyed(s, current: IDs.hebrew), [
            .header("In Notes"),
            .languageKey("Always use", key(nil)),
            .action("Follow My Last Switch", .unpinCurrent, checked: true),
            .separator,
            .action("Turn Off Double-Shift in Notes", .toggleConvertInCurrentApp),
            .action("Forget Rule for Notes", .forgetCurrent),
        ], "a learned rule: no half filled, Follow My Last Switch checked")
    }

    func testPinnedRuleFillsItsHalf() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew, .pinned))
        let all = keyed(s, current: IDs.abc)
        XCTAssertEqual(all[1], .languageKey("Always use", key(.b)))
        XCTAssertEqual(all[2], .action("Follow My Last Switch", .unpinCurrent, checked: false))
        XCTAssertEqual(all[5], .action("Forget Rule for Notes", .forgetCurrent), "a pinned rule can be forgotten")
    }

    /// P6-0g: a click on the other half pins it; on the filled half, unpins (back to the learned rule).
    func testTheKeysHalvesPinAndUnpin() {
        XCTAssertEqual(key(nil).action(for: .a), .pinCurrentTo(IDs.abc))
        XCTAssertEqual(key(nil).action(for: .b), .pinCurrentTo(IDs.hebrew))
        XCTAssertEqual(key(.b).action(for: .a), .pinCurrentTo(IDs.abc), "both languages can be chosen (review P2)")
        XCTAssertEqual(key(.b).action(for: .b), .unpinCurrent)
    }

    func testAPinOutsideThePairIsNamed() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.russian, .pinned))
        let all = keyed(s)
        XCTAssertEqual(all[1], .languageKey("Always use", key(nil)))
        XCTAssertEqual(all[2], .info("Always com.apple.keylayout.Russian"))
        XCTAssertEqual(all[3], .action("Follow My Last Switch", .unpinCurrent, checked: false))
    }

    func testAPinOfABroaderScopeIsNotThisPin() {
        // A site context whose pin scope is the host: the site's pin isn't this scope's.
        var s = MenuState()
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .pinned,
                        updatedAt: Date(timeIntervalSince1970: 1))
        s.currentRule = rule(matched: site, level: .site, pinScope: .siteHost(host: "www.ynet.co.il"))
        XCTAssertEqual(keyed(s)[1], .languageKey("Always use", key(nil)))
    }

    func testNoPairKnownPinsTheCurrentLanguage() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew, .pinned))
        XCTAssertEqual(context(s, current: IDs.hebrew)[1], .action("Always Use Hebrew", .unpinCurrent, checked: true))
        XCTAssertEqual(context(s, current: IDs.abc)[1], .action("Always Use English", .pinCurrent),
                       "P6-0g: the language’s name, not the layout’s")
    }

    func testNoRule() {
        var s = MenuState()
        s.currentRule = rule()
        XCTAssertEqual(keyed(s), [
            .header("In Notes"),
            .languageKey("Always use", key(nil)),
            .action("Follow My Last Switch", .unpinCurrent, checked: true),
            .separator,
            .action("Turn Off Double-Shift in Notes", .toggleConvertInCurrentApp),
        ], "no rule: nothing to forget")
    }

    func testDefaultRuleHasNothingToForget() {
        var s = MenuState()
        s.currentRule = rule(level: .defaultRule, target: IDs.hebrew)
        let all = keyed(s)
        XCTAssertEqual(all[0], .header("In Notes"))
        XCTAssertFalse(titles(all).contains { $0.hasPrefix("Forget") }, "the default is no rule of its own")
    }

    func testTurnOffDoubleShiftIsCheckedWhenTheAppHasDoubleShiftOff() {
        var s = MenuState()
        s.currentRule = rule()
        s.convertOffInCurrentApp = true
        XCTAssertEqual(keyed(s)[4], .action("Turn Off Double-Shift in Notes", .toggleConvertInCurrentApp, checked: true))
    }

    func testUnknownCurrentSourceStillOffersTheKey() {
        var s = MenuState()
        s.currentRule = rule()
        XCTAssertEqual(keyed(s, current: nil)[1], .languageKey("Always use", key(nil)))
        XCTAssertEqual(context(s, current: nil).map(\.title), ["In Notes", "Follow My Last Switch", "—",
                                                               "Turn Off Double-Shift in Notes"].map { $0 == "—" ? "" : $0 },
                       "no pair and no current language: nothing to pin")
    }

    func testUnknownAppShowsItsBundleID() {
        var s = MenuState()
        s.currentRule = SwitchController.CurrentRule(
            context: Context(bundleID: "com.example.gone", pid: 3, generation: 1),
            resolution: Resolution(target: nil, matched: nil, level: .none), pinScope: .app(bundleID: "com.example.gone"))
        XCTAssertEqual(keyed(s)[0], .header("In com.example.gone"))
    }

    func testEveryItemHasTheSameInset() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        s.pairInputSources = pair
        XCTAssertTrue(items(s, settings: true).allSatisfy { $0.indent == 0 }, "P6-0g (review P3): one left inset")
    }

    /// P6-0g: the letters come from the language; without one, from the name.
    func testKeyLettersFallBackToTheName() {
        var s = MenuState()
        s.currentRule = rule()
        s.pairInputSources = pair
        let all = MenuModel.contextItems(state: s, currentSource: nil, sourceName: { self.sourceNames[$0] ?? "" },
                                         appName: { self.names[$0] ?? $0 })
        guard case .languageKey(let k) = all[1].kind else { return XCTFail("no key") }
        XCTAssertEqual([k.a.letters, k.b.letters], ["EN", "HE"])
    }

    func testScopeNames() {
        let app: (String) -> String = { self.names[$0] ?? $0 }
        XCTAssertEqual(MenuModel.scopeName(.app(bundleID: notes), appName: app), "Notes")
        XCTAssertEqual(MenuModel.scopeName(.site(domain: "ynet.co.il"), appName: app), "ynet.co.il")
        XCTAssertEqual(MenuModel.scopeName(.siteHost(host: "docs.google.com"), appName: app), "docs.google.com")
        XCTAssertEqual(MenuModel.scopeName(.chat(bundleID: "com.tinyspeck.slackmacgap",
                                                 key: ChatKey(kind: .id, value: "T1/C1")), appName: app),
                       "this chat in Slack")
    }

    func testSiteRuleNamesTheSite() {
        var s = MenuState()
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned,
                        updatedAt: Date(timeIntervalSince1970: 1))
        s.currentRule = rule(matched: site, level: .site, pinScope: .siteHost(host: "www.ynet.co.il"))
        let all = keyed(s)
        XCTAssertEqual(all[0].title, "In www.ynet.co.il")
        XCTAssertEqual(all.last?.title, "Forget Rule for ynet.co.il")
    }

    // MARK: - Pause

    func testPauseAndResume() {
        XCTAssertNotNil(item("Pause Kytkin", in: items(MenuState())))
        var s = MenuState()
        s.paused = true
        let all = items(s)
        XCTAssertEqual(item("Resume Kytkin", in: all)?.kind, .action(.togglePause))
        XCTAssertFalse(titles(all).contains("Pause Kytkin"))
    }

    // MARK: - Warnings: which, and in what order

    func testNoWarningsByDefault() {
        XCTAssertEqual(MenuWarning.list(for: MenuState()), [])
        var s = MenuState()
        s.accessibility = .granted
        s.inputMonitoring = .denied
        s.tapMode = .active
        s.paused = true
        XCTAssertEqual(MenuWarning.list(for: s), [], "Pause is the Resume item, not a warning")
    }

    func testEveryWarningInOrder() {
        var s = MenuState()
        s.enabled = false
        s.showsQuitAndReopen = true
        s.accessibility = .denied
        s.inputMonitoring = .granted
        s.conflicts = Conflicts(runningSwitchers: ["FlicKey"], perDocumentInputEnabled: true)
        s.degradedByWatchdog = true
        s.canRestartKeyboard = true
        s.secureInputOn = true
        s.store = .init(loadIssue: .newerSchemaReadOnly, isReadOnly: true, lastSaveFailed: true, loadWasLossy: true,
                        originalBackupURL: URL(fileURLWithPath: "/tmp/p.lossy.bak.json"))
        XCTAssertEqual(MenuWarning.list(for: s), [
            .kytkinOff, .quitAndReopen, .accessibilityNeeded(toggleStillWorks: true), .otherSwitchers(["FlicKey"]),
            .perDocumentInput, .keyboardSlowedDown(canRestart: true), .secureInput,
            .settingsReadOnly(newerVersion: true),
            .settingsPartlyReset(original: URL(fileURLWithPath: "/tmp/p.lossy.bak.json")),
        ])
    }

    func testAccessibilityWarningOnlyForDeniedOrNotAsked() {
        for (state, expected) in [(PermissionState.granted, false), (.unknown, false), (.denied, true),
                                  (.notDetermined, true)] {
            var s = MenuState()
            s.accessibility = state
            XCTAssertEqual(MenuWarning.list(for: s).contains(.accessibilityNeeded(toggleStillWorks: false)), expected,
                           "\(state)")
        }
    }

    // MARK: - Warning lines (P6-0c: one clickable ⚠ line each, the fix as its subtitle; copy review M-11…M-21)

    func testAccessibilityTexts() {
        var s = MenuState()
        s.accessibility = .notDetermined
        XCTAssertEqual(warningLines(s), [.info("Double-Shift and website rules are off: Accessibility is off",
                                               symbol: warn)])
        s.inputMonitoring = .granted
        XCTAssertEqual(warningLines(s, settings: true), [
            .action("Double-Shift can’t convert: Accessibility is off", .openSettings(.permissions), symbol: warn,
                    subtitle: "Allow Accessibility…"),
        ])
    }

    func testOtherSwitchersAreNamedAndOnlyWarned() {
        var s = MenuState()
        s.conflicts.runningSwitchers = ["FlicKey"]
        XCTAssertEqual(warningLines(s, settings: true), [
            .action("FlicKey also switches languages", .openSettings(.general), symbol: warn,
                    subtitle: "Quit it so the two don’t undo each other"),
        ], "owner 2026-11-17: a warning only, no Quit button")
        s.conflicts.runningSwitchers = ["FlicKey", "Punto"]
        XCTAssertEqual(titles(warningLines(s)), ["FlicKey and Punto also switch languages"])
        s.conflicts.runningSwitchers = ["A", "B", "C"]
        XCTAssertEqual(warningLines(s)[0].title, "A, B and C also switch languages")
    }

    func testPerDocumentInputPointsToSettings() {
        // P6-0c (copy review M-14, P1): the old System Settings path in the menu was wrong.
        var s = MenuState()
        s.conflicts.perDocumentInputEnabled = true
        XCTAssertEqual(warningLines(s, settings: true), [
            .action("Not learning: macOS is switching languages per document", .openSettings(.permissions),
                    symbol: warn, subtitle: "How to Turn It Off…"),
        ])
    }

    func testQuitAndReopen() {
        var s = MenuState()
        s.showsQuitAndReopen = true
        XCTAssertEqual(warningLines(s), [.action("Quit & Reopen Kytkin to finish setup", .quitAndReopen, symbol: warn,
                                                 subtitle: "Kytkin opens again by itself")])
    }

    func testKeyboardSlowdownOffersARestartOnlyWhenItCanHelp() {
        var s = MenuState()
        s.degradedByWatchdog = true
        XCTAssertEqual(warningLines(s), [.info("Double-Shift stopped after a slowdown", symbol: warn)])
        s.canRestartKeyboard = true
        XCTAssertEqual(warningLines(s), [.action("Double-Shift stopped after a slowdown", .restartKeyboard,
                                                 symbol: warn, subtitle: "Start Double-Shift Again")])
        s.degradedByWatchdog = false
        XCTAssertEqual(warningLines(s), [], "canRestart alone shows nothing")
    }

    /// P2-57 item 1 / P2-52 item 2: below the desired mode for any other reason is never silent.
    func testKeyboardFeaturesOffWhileBelowDesired() {
        var s = MenuState()
        s.keyboardBelowDesired = true
        XCTAssertEqual(MenuWarning.list(for: s), [.keyboardFeaturesOff(canRestart: false)])
        XCTAssertEqual(warningLines(s), [.info("Double-Shift is off", symbol: warn)])
        s.canRestartKeyboard = true
        XCTAssertEqual(warningLines(s), [.action("Double-Shift is off", .restartKeyboard, symbol: warn,
                                                 subtitle: "Start Double-Shift Again")])
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: s).look, .attention, "marks the label")
    }

    func testWatchdogKeepsItsOwnWordingWhileBelowDesired() {
        var s = MenuState()
        s.keyboardBelowDesired = true
        s.degradedByWatchdog = true
        s.canRestartKeyboard = true
        XCTAssertEqual(MenuWarning.list(for: s), [.keyboardSlowedDown(canRestart: true)])
        XCTAssertEqual(warningLines(s)[0].title, "Double-Shift stopped after a slowdown")
    }

    func testKeyboardFeaturesOffNotWhilePausedOffOrNeedingARelaunch() {
        var s = MenuState()
        s.keyboardBelowDesired = true
        s.paused = true
        XCTAssertEqual(MenuWarning.list(for: s), [])
        s.paused = false
        s.enabled = false
        XCTAssertEqual(MenuWarning.list(for: s), [.kytkinOff])
        s.enabled = true
        s.showsQuitAndReopen = true
        XCTAssertEqual(MenuWarning.list(for: s), [.quitAndReopen], "Quit & Reopen is the remedy there")
    }

    func testSecureInputIsInfoOnly() {
        var s = MenuState()
        s.secureInputOn = true
        XCTAssertEqual(warningLines(s), [.info("Double-Shift waits: another app is protecting your typing",
                                               symbol: warn)])
    }

    // MARK: - Preferences file (S1)

    func testReadOnlyTexts() {
        var s = MenuState()
        s.store = .init(loadIssue: .newerSchemaReadOnly, isReadOnly: true)
        XCTAssertEqual(warningLines(s, settings: true), [.action("Settings are from a newer Kytkin",
                                                                 .openSettings(.general), symbol: warn,
                                                                 subtitle: "Update Kytkin to change them")])
        s.store = .init(loadIssue: .unreadable, isReadOnly: true)
        XCTAssertEqual(titles(warningLines(s)), ["Settings couldn’t be read"])
    }

    func testSaveFailed() {
        var s = MenuState()
        s.store.lastSaveFailed = true
        XCTAssertEqual(warningLines(s), [.info("Settings couldn’t be saved. Changes last until you quit.",
                                               symbol: warn)])
        s.store.isReadOnly = true
        XCTAssertEqual(MenuWarning.list(for: s), [.settingsReadOnly(newerVersion: false)], "read-only says it all")
    }

    func testLossyLoad() {
        var s = MenuState()
        s.store.loadWasLossy = true
        XCTAssertEqual(warningLines(s), [.info("Some settings couldn’t be read and were reset", symbol: warn)])
        let url = URL(fileURLWithPath: "/tmp/preferences.lossy-x.bak.json")
        s.store.originalBackupURL = url
        XCTAssertEqual(warningLines(s), [.action("Some settings couldn’t be read and were reset", .revealFile(url),
                                                 symbol: warn, subtitle: "Show Original File")])
    }

    func testCorruptFileWasReset() {
        var s = MenuState()
        let url = URL(fileURLWithPath: "/tmp/preferences.corrupt-x.json")
        s.store.loadIssue = .corruptQuarantined(url)
        XCTAssertEqual(warningLines(s), [.action("Settings were damaged, so Kytkin started fresh", .revealFile(url),
                                                 symbol: warn, subtitle: "Show Old File")])
    }

    func testMigrationIsNotAWarning() {
        var s = MenuState()
        s.store.loadIssue = .migrated(from: 0)
        XCTAssertEqual(MenuWarning.list(for: s), [])
    }

    // MARK: - Settings hook gating

    func testWithoutSettingsNoOpenSettingsHints() {
        var s = MenuState()
        s.accessibility = .denied
        let all = items(s, settings: false)
        XCTAssertFalse(all.contains { if case .action(.openSettings(let t)) = $0.kind { t != .general } else { false } })
        XCTAssertEqual(item("Settings…", in: all)?.isEnabled, false)
        XCTAssertTrue(all.contains { $0.title.hasPrefix("Double-Shift") && $0.kind == .info }, "still says it")
    }

    // MARK: - Wording rules

    func testNoImplementationWordsOutsideDebugLines() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        s.enabled = false
        s.showsQuitAndReopen = true
        s.accessibility = .denied
        s.conflicts = Conflicts(runningSwitchers: ["FlicKey", "X"], perDocumentInputEnabled: true)
        s.degradedByWatchdog = true
        s.canRestartKeyboard = true
        s.secureInputOn = true
        s.store = .init(loadIssue: .corruptQuarantined(URL(fileURLWithPath: "/tmp/c.json")), isReadOnly: true)
        let user = items(s, settings: true, debug: true).filter { $0.title != "Debug" }
        for i in user {
            for word in ["tap", "TIS", "watchdog", "AX", "pid", "bundle", "schema", "Secure Input"] {
                XCTAssertNil(i.title.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]),
                             "\"\(i.title)\" says \(word)")
            }
            XCTAssertLessThanOrEqual(i.title.count, 64, "\"\(i.title)\" is long for a menu")
        }
    }

    // MARK: - Label (P6-0c: icon + letters, looks, VoiceOver; visual review §3.2, copy review M-1/M-2)

    func testLabel() {
        let en = MenuModel.label(languageCode: "en", languageName: "English", state: MenuState())
        XCTAssertEqual(en, .init(look: .active, letters: "EN", showsIcon: true, accessibilityLabel: "Kytkin, English"))
        XCTAssertEqual(MenuModel.label(languageCode: "he-IL", state: MenuState()).letters, "HE")
        let unknown = MenuModel.label(languageCode: nil, state: MenuState())
        XCTAssertNil(unknown.letters, "copy review M-1: no \"?\"")
        XCTAssertTrue(unknown.showsIcon)
        XCTAssertEqual(unknown.accessibilityLabel, "Kytkin")
        XCTAssertEqual(MenuModel.label(languageCode: "", state: MenuState()).letters, nil)
        XCTAssertEqual(en.imageName, "kytkin-menubar-active-a")
    }

    func testDisplayModes() {
        let s = MenuState()
        let iconOnly = MenuModel.label(languageCode: "he", state: s, display: .iconOnly)
        XCTAssertNil(iconOnly.letters)
        XCTAssertTrue(iconOnly.showsIcon)
        let lettersOnly = MenuModel.label(languageCode: "he", state: s, display: .languageOnly)
        XCTAssertEqual(lettersOnly.letters, "HE")
        XCTAssertFalse(lettersOnly.showsIcon)
        XCTAssertTrue(MenuModel.label(languageCode: nil, state: s, display: .languageOnly).showsIcon,
                      "never an empty item")
    }

    func testPausedLabelIsDimmedWithItsOwnLook() {
        var s = MenuState()
        s.paused = true
        let l = MenuModel.label(languageCode: "he", languageName: "Hebrew", state: s)
        XCTAssertEqual(l.look, .paused)
        XCTAssertTrue(l.dimmed)
        XCTAssertEqual(l.letters, "HE", "no more trailing dot")
        XCTAssertEqual(l.accessibilityLabel, "Kytkin, Hebrew, paused")
        XCTAssertEqual(l.imageName, "kytkin-menubar-paused-a")
    }

    func testOffWinsOverPausedAndWarnings() {
        var s = MenuState()
        s.enabled = false
        s.paused = true
        s.conflicts.runningSwitchers = ["FlicKey"]
        let l = MenuModel.label(languageCode: "he", languageName: "Hebrew", state: s)
        XCTAssertEqual(l.look, .off)
        XCTAssertTrue(l.dimmed)
        XCTAssertEqual(l.accessibilityLabel, "Kytkin, Hebrew, turned off")
        s.enabled = true
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s).look, .paused)
    }

    func testWarningsMarkTheLabelExceptSecureInput() {
        var s = MenuState()
        s.secureInputOn = true
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: s).look, .active, "would flicker per password field")
        s.conflicts.runningSwitchers = ["FlicKey"]
        let l = MenuModel.label(languageCode: "en", languageName: "English", state: s)
        XCTAssertEqual(l.look, .attention)
        XCTAssertFalse(l.dimmed)
        XCTAssertEqual(l.accessibilityLabel, "Kytkin, English, needs attention")
    }

    func testLabelIgnoresDebugOnlyChanges() {
        var a = MenuState()
        var b = MenuState()
        b.doubleShiftCount = 9
        b.tapReEnableCount = 4
        b.currentRule = rule(matched: .app(notes, IDs.hebrew))
        a.tapMode = .active
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: a), MenuModel.label(languageCode: "en", state: b),
                       "counters and the context line never change the button")
    }

    // MARK: - P6-0e: the artwork (docs/design/artwork/Colors.md)

    func testTheFilledHalfIsTheLanguageThatIsOn() {
        var s = MenuState()
        s.pairInputSources = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: s, current: IDs.abc).side, .a)
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew).side, .b)
        XCTAssertEqual(MenuModel.label(languageCode: "ru", state: s, current: IDs.russian).side, .a, "not in the pair")
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s).side, .a, "unknown current source")
        s.pairInputSources = nil
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew).side, .a, "no pair known")
        XCTAssertEqual(MenuModel.side(of: IDs.hebrew, in: LanguagePair(a: IDs.hebrew, b: IDs.hebrew)), .a,
                       "a pair with one member twice: the first")
    }

    func testEveryLookAndSideHasItsGlyphName() {
        var names: [String] = []
        for look in MenuModel.Label.Look.allCases {
            for side in [PairSide.a, .b] { names.append(MenuModel.glyphName(look, side: side)) }
        }
        XCTAssertEqual(names, ["kytkin-menubar-active-a", "kytkin-menubar-active-b", "kytkin-menubar-paused-a",
                               "kytkin-menubar-paused-b", "kytkin-menubar-attention-a", "kytkin-menubar-attention-b",
                               "kytkin-menubar-off-a", "kytkin-menubar-off-b"])
    }

    func testStatesMapToLooksAndOnlyOffFadesTheLetters() {
        var s = MenuState()
        s.pairInputSources = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        let active = MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew)
        XCTAssertEqual(active.imageName, "kytkin-menubar-active-b")
        XCTAssertEqual(active.lettersOpacity, 1)
        s.paused = true
        let paused = MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew)
        XCTAssertEqual(paused.imageName, "kytkin-menubar-paused-b")
        XCTAssertEqual(paused.lettersOpacity, 1, "paused: only the glyph’s fill changes")
        s.paused = false
        s.conflicts.runningSwitchers = ["FlicKey"]
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew).imageName,
                       "kytkin-menubar-attention-b")
        s.enabled = false
        let off = MenuModel.label(languageCode: "he", state: s, current: IDs.hebrew)
        XCTAssertEqual(off.imageName, "kytkin-menubar-off-b")
        XCTAssertEqual(off.lettersOpacity, 0.35, "off: the letters fade to 35 % too")
        XCTAssertEqual(off.letters, "HE", "the language is still shown")
    }

    /// P6-0e: AppController tells the label the pair as input sources.
    func testMenuStateCarriesThePairForTheGlyph() {
        XCTAssertNil(MenuState().pairInputSources)
    }

    /// P6-0e QA: the item's width depends on the display mode only: not on the language, on its letters being known,
    /// on the look (off, paused, attention) or on the pair side, so the items beside Kytkin never move.
    func testTheItemWidthIsFixedPerDisplayMode() {
        var states: [MenuState] = []
        var active = MenuState()
        active.pairInputSources = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        states.append(active)
        var paused = active; paused.paused = true; states.append(paused)
        var off = active; off.enabled = false; states.append(off)
        var attention = active; attention.secureInputOn = true; states.append(attention)
        for display in Preferences.General.MenuBarLabel.allCases {
            var widths = Set<Double>()
            for state in states {
                for (code, current) in [("en", IDs.abc), ("he", IDs.hebrew), (nil, nil), ("fil", nil)] as [(String?, InputSourceID?)] {
                    let label = MenuModel.label(languageCode: code, state: state, display: display, current: current)
                    XCTAssertEqual(label.display, display)
                    widths.insert(MenuModel.ItemLayout.width(for: label.display))
                }
            }
            XCTAssertEqual(widths.count, 1, "\(display)")
        }
        XCTAssertEqual(MenuModel.ItemLayout.width(for: .iconAndLanguage), 43, "P6-0g: a 5 pt gap")
        XCTAssertEqual(MenuModel.ItemLayout.width(for: .iconOnly), 18)
        XCTAssertEqual(MenuModel.ItemLayout.width(for: .languageOnly), 28)
    }

    /// P6-0e QA: the filled half for a language outside the pair, or an unknown pair, is the first one.
    func testTheGlyphSideOutsideThePair() {
        let pair = LanguagePair(a: IDs.abc, b: IDs.hebrew)
        XCTAssertEqual(MenuModel.side(of: IDs.hebrew, in: pair), .b)
        XCTAssertEqual(MenuModel.side(of: IDs.abc, in: pair), .a)
        XCTAssertEqual(MenuModel.side(of: InputSourceID("com.apple.keylayout.Russian"), in: pair), .a)
        XCTAssertEqual(MenuModel.side(of: IDs.hebrew, in: nil), .a)
        XCTAssertEqual(MenuModel.side(of: IDs.hebrew, in: LanguagePair(a: IDs.hebrew, b: IDs.hebrew)), .a)
    }
}
