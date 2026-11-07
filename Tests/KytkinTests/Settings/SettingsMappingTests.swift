// P2-23: The pure Settings mappings: tab list and placeholders, the "no rule" picker options, the preferences-file
// notices, and the About text from Info.plist.

import XCTest

final class SettingsMappingTests: XCTestCase {
    private func info(_ id: InputSourceID, _ name: String, enabled: Bool = true) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: "", isEnabled: enabled, isConvertible: true,
                        isInputMethod: false)
    }

    // MARK: - Tabs

    func testTabOrderAndPlaceholders() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title),
                       ["General", "Languages", "Rules", "Convert", "Apps", "Permissions", "About"])
        XCTAssertEqual(SettingsTab.allCases.filter { !$0.isPlaceholder },
                       [.general, .languages, .rules, .convert, .apps, .about])
        for tab in SettingsTab.allCases {
            XCTAssertFalse(tab.symbolName.isEmpty)
            XCTAssertEqual(tab.comingSoonText.isEmpty, !tab.isPlaceholder, "\(tab)")
            if tab.isPlaceholder { XCTAssertTrue(tab.comingSoonText.contains("coming soon"), "\(tab)") }
        }
    }

    @MainActor func testSelectionDefaultsToGeneral() {
        XCTAssertEqual(SettingsSelection().tab, .general)
        XCTAssertEqual(SettingsSelection(tab: .about).tab, .about)
    }

    // MARK: - "When an app has no rule"

    func testOptionsListEnabledSourcesOnceAfterKeepCurrent() {
        let opts = DefaultBehaviorOption.options(current: .keepCurrent, sources: [
            info(IDs.abc, "ABC"), info(IDs.russian, "Russian", enabled: false), info(IDs.hebrew, "Hebrew"),
            info(IDs.abc, "ABC again"), info(InputSourceID(""), "Blank"),
        ])
        XCTAssertEqual(opts.map(\.title), ["Leave the language as it is", "Switch to ABC", "Switch to Hebrew"])
        XCTAssertEqual(opts.map(\.behavior), [.keepCurrent, .switchTo(IDs.abc), .switchTo(IDs.hebrew)])
        XCTAssertEqual(Set(opts.map(\.id)).count, opts.count, "ids are unique")
    }

    func testSavedSourceThatIsNotEnabledIsStillListed() {
        let opts = DefaultBehaviorOption.options(current: .switchTo(IDs.russian), sources: [info(IDs.abc, "ABC")])
        XCTAssertEqual(opts.last?.title, "Switch to Russian (not turned on)")
        XCTAssertEqual(opts.last?.id, DefaultBehaviorOption.id(for: .switchTo(IDs.russian)))
        XCTAssertEqual(opts.count, 3)
    }

    func testSavedEnabledSourceIsNotListedTwice() {
        let opts = DefaultBehaviorOption.options(current: .switchTo(IDs.abc), sources: [info(IDs.abc, "ABC")])
        XCTAssertEqual(opts.count, 2)
    }

    func testNamelessSourceUsesTheLastPartOfItsID() {
        let opts = DefaultBehaviorOption.options(current: .keepCurrent, sources: [info(IDs.hebrew, "")])
        XCTAssertEqual(opts.last?.title, "Switch to Hebrew")
        XCTAssertEqual(DefaultBehaviorOption.fallbackName(InputSourceID("plain")), "plain")
    }

    // MARK: - Notices

    func testNoticeForEachStoreState() {
        let backup = URL(fileURLWithPath: NSHomeDirectory() + "/Library/x/preferences.lossy.bak.json")
        XCTAssertTrue(SettingsNotice.notices(loadIssue: nil, isReadOnly: false, lastSaveFailed: false,
                                             loadWasLossy: false, originalBackupURL: nil).isEmpty)
        XCTAssertEqual(SettingsNotice.notices(loadIssue: .migrated(from: 0), isReadOnly: false, lastSaveFailed: false,
                                              loadWasLossy: false, originalBackupURL: nil), [])

        let newer = SettingsNotice.notices(loadIssue: .newerSchemaReadOnly, isReadOnly: true, lastSaveFailed: false,
                                           loadWasLossy: false, originalBackupURL: nil)
        XCTAssertEqual(newer.map(\.kind), [.readOnly])
        XCTAssertTrue(newer[0].message.contains("newer version"))

        let unreadable = SettingsNotice.notices(loadIssue: .unreadable, isReadOnly: true, lastSaveFailed: true,
                                                loadWasLossy: false, originalBackupURL: nil)
        XCTAssertEqual(unreadable.map(\.kind), [.readOnly], "a read-only store never saves, so no save notice")
        XCTAssertTrue(unreadable[0].message.contains("couldn't read"))

        XCTAssertEqual(SettingsNotice.notices(loadIssue: nil, isReadOnly: false, lastSaveFailed: true,
                                              loadWasLossy: false, originalBackupURL: nil).map(\.kind), [.saveFailed])

        let lossy = SettingsNotice.notices(loadIssue: nil, isReadOnly: false, lastSaveFailed: false,
                                           loadWasLossy: true, originalBackupURL: backup)
        XCTAssertEqual(lossy.map(\.kind), [.lossy])
        XCTAssertTrue(lossy[0].message.contains("~/Library/x/preferences.lossy.bak.json"), lossy[0].message)
        let lossyNoBackupYet = SettingsNotice.notices(loadIssue: nil, isReadOnly: false, lastSaveFailed: false,
                                                      loadWasLossy: true, originalBackupURL: nil)
        XCTAssertEqual(lossyNoBackupYet[0].message, "Some settings couldn't be read and were reset.")

        let corrupt = SettingsNotice.notices(loadIssue: .corruptQuarantined(backup), isReadOnly: false,
                                             lastSaveFailed: false, loadWasLossy: false, originalBackupURL: nil)
        XCTAssertEqual(corrupt.map(\.kind), [.quarantined])
        XCTAssertTrue(corrupt[0].message.contains("~/Library/x/"))
    }

    // MARK: - About

    func testAboutFromInfoPlist() {
        let about = AboutInfo(infoDictionary: ["CFBundleDisplayName": "Kytkin Dev", "CFBundleName": "Kytkin Dev",
                                               "CFBundleShortVersionString": "0.0.1", "CFBundleVersion": "1"])
        XCTAssertEqual(about.name, "Kytkin Dev")
        XCTAssertEqual(about.version, "Version 0.0.1 (1)")
        XCTAssertTrue(about.license.contains("MIT License"))
        XCTAssertTrue(about.cleanRoom.contains("clean-room"))
        XCTAssertEqual(about.repositoryURL.absoluteString, "https://github.com/dishontomer5-coder/kytkin")
        XCTAssertEqual(about.repositoryText, "github.com/dishontomer5-coder/kytkin")
    }

    func testAboutWithMissingKeys() {
        let about = AboutInfo(infoDictionary: ["CFBundleName": "Kytkin", "CFBundleDisplayName": ""])
        XCTAssertEqual(about.name, "Kytkin")
        XCTAssertEqual(about.version, "Version unknown")
        XCTAssertEqual(AboutInfo(infoDictionary: [:]).name, "Kytkin")
        XCTAssertEqual(AboutInfo(infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": ""]).version,
                       "Version 1.2")
    }
}
