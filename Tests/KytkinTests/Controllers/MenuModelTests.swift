// P2-22: MenuModel and MenuWarning (001 §5.1, §6.2, §12.1 S1): every line of the menu-bar menu, its text, enabled and
// checked state, order, the "Open Settings…" hook gating, the DEBUG lines, and the label (dot, dimmed, P2-52 item 4).

import XCTest

@MainActor
final class MenuModelTests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let names = ["com.apple.Notes": "Notes", "com.tinyspeck.slackmacgap": "Slack"]
    private let sourceNames = [IDs.abc: "ABC", IDs.hebrew: "Hebrew"]

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
        MenuModel.items(state: state, currentSource: current.map(source), version: "1.2.3",
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

    /// Only the lines a warning adds (between the Pause item's separator and the Settings separator).
    private func warningLines(_ state: MenuState, settings: Bool = false) -> [MenuItemModel] {
        MenuWarning.list(for: state).flatMap { MenuModel.items(for: $0, settingsAvailable: settings) }
    }

    // MARK: - Whole layout

    func testQuietMenuLayout() {
        XCTAssertEqual(items(MenuState()), [
            .info("No app yet"),
            .action("Pause Kytkin", .togglePause),
            .separator,
            .action("Settings…", .openSettings(.general), enabled: false, key: ","),
            .info("Kytkin v1.2.3"),
            .separator,
            .action("Quit Kytkin", .quit, key: "q"),
        ])
    }

    func testFullLayoutWithRuleSettingsAndAWarning() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        s.secureInputOn = true
        XCTAssertEqual(titles(items(s, settings: true)), [
            "Notes: Hebrew (learned)",
            "Always use ABC in Notes",
            "Forget rule for Notes",
            "Pause Kytkin",
            "—",
            "Typing protected by another app",
            "—",
            "Settings…",
            "About Kytkin v1.2.3",
            "—",
            "Quit Kytkin",
        ])
        let all = items(s, settings: true)
        XCTAssertEqual(item("Settings…", in: all)?.isEnabled, true)
        XCTAssertEqual(item("Settings…", in: all)?.keyEquivalent, ",")
        XCTAssertEqual(item("About Kytkin v1.2.3", in: all)?.kind, .action(.openSettings(.about)))
        XCTAssertEqual(item("Quit Kytkin", in: all)?.keyEquivalent, "q")
    }

    func testDebugLinesComeBeforeQuit() {
        var s = MenuState()
        s.tapMode = .listenOnly
        s.degradedByWatchdog = true
        s.doubleShiftCount = 3
        s.tapReEnableCount = 2
        let all = items(s, debug: true)
        let t = titles(all)
        XCTAssertEqual(Array(t.suffix(7)), [
            "—",
            "DEBUG: Keyboard: listenOnly (lowered)",
            "DEBUG: Double-Shift count: 3",
            "DEBUG: Tap re-enables: 2",
            "DEBUG: Switch to",
            "—",
            "Quit Kytkin",
        ])
        XCTAssertEqual(item("DEBUG: Switch to", in: all)?.kind, .debugSwitchSubmenu)
        XCTAssertFalse(titles(items(s)).contains { $0.hasPrefix("DEBUG") }, "Release: no DEBUG lines")
    }

    // MARK: - Context line, Pin, Forget

    func testLearnedRule() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        let all = items(s, current: IDs.hebrew)
        XCTAssertEqual(all[0], .info("Notes: Hebrew (learned)"))
        XCTAssertEqual(all[1], .action("Always use Hebrew in Notes", .pinCurrent))
        XCTAssertEqual(all[2], .action("Forget rule for Notes", .forgetCurrent))
    }

    func testPinnedToTheCurrentSourceIsCheckedAndDisabled() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew, .pinned))
        let all = items(s, current: IDs.hebrew)
        XCTAssertEqual(all[0], .info("Notes: Hebrew (pinned)"))
        XCTAssertEqual(all[1], .action("Always use Hebrew in Notes", .pinCurrent, enabled: false, checked: true))
        XCTAssertEqual(all[2].isEnabled, true, "a pinned rule can be forgotten")
    }

    func testPinnedToAnotherSourceCanBeRepinned() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew, .pinned))
        XCTAssertEqual(items(s, current: IDs.abc)[1], .action("Always use ABC in Notes", .pinCurrent))
    }

    func testLearnedRuleForTheCurrentSourceCanStillBePinned() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.hebrew))
        XCTAssertEqual(items(s, current: IDs.hebrew)[1].isEnabled, true)
        XCTAssertEqual(items(s, current: IDs.hebrew)[1].isChecked, false)
    }

    func testNoRule() {
        var s = MenuState()
        s.currentRule = rule()
        let all = items(s)
        XCTAssertEqual(all[0], .info("Notes: no rule"))
        XCTAssertEqual(all[1], .action("Always use ABC in Notes", .pinCurrent))
        XCTAssertEqual(all[2], .action("Forget rule for Notes", .forgetCurrent, enabled: false))
    }

    func testDefaultRuleSaysDefault() {
        var s = MenuState()
        s.currentRule = rule(level: .defaultRule, target: IDs.hebrew)
        let all = items(s)
        XCTAssertEqual(all[0], .info("Notes: Hebrew (default)"))
        XCTAssertEqual(all[2].isEnabled, false, "nothing to forget")
    }

    func testUnknownCurrentSourceDisablesPin() {
        var s = MenuState()
        s.currentRule = rule()
        XCTAssertEqual(items(s, current: nil)[1],
                       .action("Always use this language in Notes", .pinCurrent, enabled: false))
    }

    func testUnknownAppShowsItsBundleID() {
        var s = MenuState()
        s.currentRule = SwitchController.CurrentRule(
            context: Context(bundleID: "com.example.gone", pid: 3, generation: 1),
            resolution: Resolution(target: nil, matched: nil, level: .none), pinScope: .app(bundleID: "com.example.gone"))
        XCTAssertEqual(items(s)[0], .info("com.example.gone: no rule"))
    }

    func testUnknownSourceShowsItsID() {
        var s = MenuState()
        s.currentRule = rule(matched: .app(notes, IDs.russian))
        XCTAssertEqual(items(s)[0], .info("Notes: com.apple.keylayout.Russian (learned)"))
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

    func testSiteRuleNamesTheSiteAndPinNamesThePinScope() {
        var s = MenuState()
        let site = Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .learned,
                        updatedAt: Date(timeIntervalSince1970: 1))
        s.currentRule = rule(matched: site, level: .site, pinScope: .siteHost(host: "www.ynet.co.il"))
        let all = items(s)
        XCTAssertEqual(all[0], .info("ynet.co.il: Hebrew (learned)"))
        XCTAssertEqual(all[1].title, "Always use ABC in www.ynet.co.il")
        XCTAssertEqual(all[2].title, "Forget rule for ynet.co.il")
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

    func testAccessibilityTexts() {
        var s = MenuState()
        s.accessibility = .notDetermined
        XCTAssertEqual(titles(warningLines(s)), ["Accessibility is off: double-Shift doesn't work"])
        s.inputMonitoring = .granted
        XCTAssertEqual(titles(warningLines(s)), ["Accessibility is off: double-Shift only switches the language"])
        XCTAssertEqual(warningLines(s, settings: true)[1],
                       .action("Open Settings…", .openSettings(.permissions), indent: 1))
    }

    func testOtherSwitchersAreNamed() {
        var s = MenuState()
        s.conflicts.runningSwitchers = ["FlicKey"]
        XCTAssertEqual(warningLines(s), [.info("FlicKey is also switching languages"),
                                         .info("Quit it so the two don't fight", indent: 1)])
        s.conflicts.runningSwitchers = ["FlicKey", "Punto"]
        XCTAssertEqual(titles(warningLines(s)), ["FlicKey and Punto are also switching languages",
                                                 "Quit them so they don't fight"])
        s.conflicts.runningSwitchers = ["A", "B", "C"]
        XCTAssertEqual(warningLines(s)[0].title, "A, B and C are also switching languages")
    }

    func testPerDocumentInputSaysLearningIsPaused() {
        var s = MenuState()
        s.conflicts.perDocumentInputEnabled = true
        XCTAssertEqual(warningLines(s), [
            .info("Learning paused: macOS switches language per document"),
            .info("Turn it off in System Settings → Keyboard → Input Sources", indent: 1),
        ])
    }

    func testQuitAndReopen() {
        var s = MenuState()
        s.showsQuitAndReopen = true
        XCTAssertEqual(warningLines(s), [.info("Quit and reopen Kytkin to finish setup"),
                                         .action("Quit & Reopen", .quitAndReopen, indent: 1)])
    }

    func testKeyboardSlowdownOffersARestartOnlyWhenItCanHelp() {
        var s = MenuState()
        s.degradedByWatchdog = true
        XCTAssertEqual(warningLines(s), [.info("Some keyboard features stopped after a slowdown")])
        s.canRestartKeyboard = true
        XCTAssertEqual(warningLines(s)[1], .action("Restart Keyboard Features", .restartKeyboard, indent: 1))
        s.degradedByWatchdog = false
        XCTAssertEqual(warningLines(s), [], "canRestart alone shows nothing")
    }

    func testSecureInput() {
        var s = MenuState()
        s.secureInputOn = true
        XCTAssertEqual(warningLines(s), [.info("Typing protected by another app")])
    }

    func testKytkinOff() {
        var s = MenuState()
        s.enabled = false
        XCTAssertEqual(warningLines(s), [.info("Kytkin is turned off")])
        XCTAssertEqual(warningLines(s, settings: true), [.info("Kytkin is turned off"),
                                                         .action("Open Settings…", .openSettings(.general), indent: 1)])
    }

    // MARK: - Preferences file (S1)

    func testReadOnlyTexts() {
        var s = MenuState()
        s.store = .init(loadIssue: .newerSchemaReadOnly, isReadOnly: true)
        XCTAssertEqual(titles(warningLines(s)), ["Settings are from a newer Kytkin: changes won't be saved"])
        s.store = .init(loadIssue: .unreadable, isReadOnly: true)
        XCTAssertEqual(titles(warningLines(s)), ["Settings file couldn't be read: changes won't be saved"])
    }

    func testSaveFailed() {
        var s = MenuState()
        s.store.lastSaveFailed = true
        XCTAssertEqual(warningLines(s), [.info("Couldn't save settings")])
        s.store.isReadOnly = true
        XCTAssertEqual(MenuWarning.list(for: s), [.settingsReadOnly(newerVersion: false)], "read-only says it all")
    }

    func testLossyLoad() {
        var s = MenuState()
        s.store.loadWasLossy = true
        XCTAssertEqual(warningLines(s), [.info("Some settings couldn't be read and were reset")])
        let url = URL(fileURLWithPath: "/tmp/preferences.lossy-x.bak.json")
        s.store.originalBackupURL = url
        XCTAssertEqual(warningLines(s)[1], .action("Show Original File", .revealFile(url), indent: 1))
    }

    func testCorruptFileWasReset() {
        var s = MenuState()
        let url = URL(fileURLWithPath: "/tmp/preferences.corrupt-x.json")
        s.store.loadIssue = .corruptQuarantined(url)
        XCTAssertEqual(warningLines(s), [.info("Settings file was damaged and was reset"),
                                         .action("Show Damaged File", .revealFile(url), indent: 1)])
    }

    func testMigrationIsNotAWarning() {
        var s = MenuState()
        s.store.loadIssue = .migrated(from: 0)
        XCTAssertEqual(MenuWarning.list(for: s), [])
    }

    // MARK: - Settings hook gating

    func testWithoutSettingsNoOpenSettingsHints() {
        var s = MenuState()
        s.enabled = false
        s.accessibility = .denied
        let all = items(s, settings: false)
        XCTAssertFalse(all.contains { if case .action(.openSettings(let t)) = $0.kind { t != .general } else { false } })
        XCTAssertEqual(item("Settings…", in: all)?.isEnabled, false)
        XCTAssertFalse(titles(all).contains("Open Settings…"))
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
        let user = items(s, settings: true, debug: true).filter { !$0.title.hasPrefix("DEBUG") }
        for i in user {
            for word in ["tap", "TIS", "watchdog", "AX", "pid", "bundle", "schema", "Secure Input"] {
                XCTAssertNil(i.title.range(of: "\\b\(word)\\b", options: [.regularExpression, .caseInsensitive]),
                             "\"\(i.title)\" says \(word)")
            }
            XCTAssertLessThanOrEqual(i.title.count, 64, "\"\(i.title)\" is long for a menu")
        }
    }

    // MARK: - Label

    func testLabel() {
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: MenuState()), .init(title: "EN", dimmed: false))
        XCTAssertEqual(MenuModel.label(languageCode: "he-IL", state: MenuState()).title, "HE")
        XCTAssertEqual(MenuModel.label(languageCode: nil, state: MenuState()).title, "?")
        XCTAssertEqual(MenuModel.label(languageCode: "", state: MenuState()).title, "?")
    }

    func testPausedLabelHasTheDotAndIsDimmed() {
        var s = MenuState()
        s.paused = true
        XCTAssertEqual(MenuModel.label(languageCode: "he", state: s), .init(title: "HE·", dimmed: true))
    }

    func testWarningsMarkTheLabelExceptSecureInput() {
        var s = MenuState()
        s.secureInputOn = true
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: s).title, "EN", "would flicker per password field")
        s.conflicts.runningSwitchers = ["FlicKey"]
        XCTAssertEqual(MenuModel.label(languageCode: "en", state: s), .init(title: "EN·", dimmed: false))
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
}
