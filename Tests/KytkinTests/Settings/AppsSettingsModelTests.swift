// P2-25: Settings → Apps logic: rows from `prefs.apps`, each control writing only real differences, the override →
// MethodHint mapping (001 §12 T5), adding from running apps or a chosen bundle ID, removing, and read-only mode.

import XCTest

@MainActor
final class AppsSettingsModelTests: XCTestCase {
    private let notes = "com.apple.Notes"
    private let term = "com.apple.Terminal"
    private let chrome = "com.google.Chrome"
    private let own = "io.github.kytkin.Kytkin.dev"

    private var store: PreferencesStore!
    private var running: [AppCandidate] = []
    private var runningReads = 0
    private var sut: AppsSettingsModel!

    private func make(_ apps: [String: Preferences.AppOverride] = [:], readOnly: Bool = false) {
        var prefs = Preferences()
        prefs.apps = apps
        store = readOnly ? makeReadOnlyStore(prefs) : makeStore(prefs, clock: FakeClock())
        let names = FakeAppNames([notes: "Notes", term: "Terminal", chrome: "Google Chrome"])
        sut = AppsSettingsModel(store: store, appName: { names.lookup($0) }, runningApps: { [unowned self] in
            self.runningReads += 1
            return self.running
        }, ownBundleID: own)
    }

    private var apps: [String: Preferences.AppOverride] { store.prefs.apps }

    // MARK: - Rows

    func testRowsAreSortedByNameWithDefaultsShown() {
        make([term: .init(), notes: .init(disabled: true), "com.example.Gone": .init(convertEnabled: false)])
        let rows = sut.rows
        XCTAssertEqual(rows.map(\.name), ["com.example.Gone", "Notes", "Terminal"])
        XCTAssertEqual(rows.map(\.kytkinOn), [true, false, true])
        XCTAssertEqual(rows.map(\.convertOn), [false, true, true])
        XCTAssertEqual(rows.map(\.methodID), ["default", "default", "default"])
        XCTAssertNil(rows[0].detail)
        XCTAssertEqual(rows[1].detail, notes)
    }

    func testEffectiveMethodFollowsT5ThenTheBuiltInChoice() {
        make([term: .init(), chrome: .init(), notes: .init(replacementMethod: .noUnicode),
              "com.example.Off": .init(convertEnabled: false, replacementMethod: .keysOnly),
              "com.example.Dis": .init(disabled: true)])
        let byID = Dictionary(uniqueKeysWithValues: sut.rows.map { ($0.bundleID, $0.effectiveMethod) })
        XCTAssertEqual(byID[term], .terminal, "the built-in terminal choice")
        XCTAssertEqual(byID[chrome], .keysOnly, "the built-in Chromium choice")
        XCTAssertEqual(byID[notes], .noUnicode)
        XCTAssertEqual(byID["com.example.Off"], .disabled)
        XCTAssertEqual(byID["com.example.Dis"], .disabled)
    }

    func testMethodOptionsShowTheBuiltInChoiceAsDefault() {
        make([chrome: .init()])
        let options = sut.methodOptions(for: sut.rows[0])
        XCTAssertEqual(options.map(\.id), ["default", "auto", "keysOnly", "noUnicode", "preferPaste", "terminal"])
        XCTAssertEqual(options[0].title, "Default (Keys only)")
        XCTAssertNil(options[0].method)
        XCTAssertTrue(options[4].title.contains("coming later"))
        XCTAssertEqual(AppMethodOption.options(for: notes)[0].title, "Default (Auto)")
    }

    // MARK: - Terminals (P2-25 QA, 001 §12 T1)

    func testATerminalOffersOnlyItsDefault() {
        make([term: .init()])
        let options = sut.methodOptions(for: sut.rows[0])
        XCTAssertEqual(options.map(\.id), ["default"], "no method that would type a selection at the prompt")
        XCTAssertEqual(options[0].title, "Default (Terminal)")
    }

    func testATerminalCantBeSetToAMethodThatTypesAtThePrompt() {
        make([term: .init()])
        for id in ["auto", "keysOnly", "noUnicode", "preferPaste", "terminal"] {
            sut.setMethod(id, for: term)
            XCTAssertNil(apps[term]?.replacementMethod, id)
        }
        XCTAssertEqual(sut.rows[0].effectiveMethod, .terminal)
    }

    func testAHandEditedTerminalMethodIsShownButNotUsed() {
        make([term: .init(replacementMethod: .auto)])
        let row = sut.rows[0]
        XCTAssertEqual(row.methodID, "auto")
        XCTAssertEqual(row.effectiveMethod, .terminal, "the terminal class wins over the file")
        let options = sut.methodOptions(for: row)
        XCTAssertEqual(options.map(\.id), ["default", "auto"], "the picker never goes blank")
        XCTAssertTrue(options[1].title.contains("not used in terminals"))
        sut.setMethod("default", for: term)
        XCTAssertNil(apps[term]?.replacementMethod, "and the user can clear it")
    }

    func testATerminalCanStillBeTurnedOff() {
        make([term: .init()])
        sut.setConvertOn(false, for: term)
        XCTAssertEqual(sut.rows[0].effectiveMethod, .disabled)
        sut.setConvertOn(true, for: term)
        sut.setKytkinOn(false, for: term)
        XCTAssertEqual(sut.rows[0].effectiveMethod, .disabled)
    }

    func testConvertOffCopySaysDoubleShiftOnlySwitches() {
        XCTAssertEqual(AppsSettingsModel.convertOffText, "When off, double-Shift only switches the language.")
    }

    // MARK: - Writes store only differences

    func testKytkinOffAndBackOn() {
        make([notes: .init()])
        sut.setKytkinOn(false, for: notes)
        XCTAssertEqual(apps[notes], .init(disabled: true))
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .disabled])
        sut.setKytkinOn(true, for: notes)
        XCTAssertEqual(apps[notes], .init(), "back on = not stored")
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [:])
    }

    func testConvertOffAndBackOn() {
        make([notes: .init()])
        sut.setConvertOn(false, for: notes)
        XCTAssertEqual(apps[notes], .init(convertEnabled: false))
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .disabled])
        sut.setConvertOn(true, for: notes)
        XCTAssertEqual(apps[notes], .init())
    }

    func testMethodChoices() {
        make([notes: .init()])
        sut.setMethod("auto", for: notes)
        XCTAssertEqual(apps[notes]?.replacementMethod, .auto)
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .auto])
        XCTAssertEqual(sut.rows[0].methodID, "auto")
        sut.setMethod("keysOnly", for: notes)
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .keysOnly])
        sut.setMethod("noUnicode", for: notes)
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .noUnicode])
        sut.setMethod("preferPaste", for: notes)
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .preferPaste])
        sut.setMethod("terminal", for: notes)
        XCTAssertEqual(PreferencesMapping.methodHintOverrides(apps), [notes: .terminal])
        XCTAssertEqual(sut.rows[0].effectiveMethod, .terminal, "any app can be made a terminal")
        sut.setMethod("default", for: notes)
        XCTAssertNil(apps[notes]?.replacementMethod)
        XCTAssertEqual(sut.rows[0].effectiveMethod, .auto, "the built-in choice again")
        sut.setMethod("bogus", for: notes)
        XCTAssertNil(apps[notes]?.replacementMethod)
    }

    func testFieldsAreIndependent() {
        make([notes: .init(autoFixEnabled: false)])
        sut.setConvertOn(false, for: notes)
        sut.setMethod("keysOnly", for: notes)
        sut.setKytkinOn(false, for: notes)
        XCTAssertEqual(apps[notes], .init(disabled: true, convertEnabled: false, autoFixEnabled: false,
                                          replacementMethod: .keysOnly), "auto-fix (P4) is kept untouched")
    }

    func testEditsToAnAppNotInTheListDoNothing() {
        make()
        sut.setKytkinOn(false, for: notes)
        sut.setConvertOn(false, for: notes)
        sut.setMethod("keysOnly", for: notes)
        XCTAssertEqual(apps, [:])
    }

    // MARK: - Add / remove

    func testRefreshListsRunningAppsNotAddedNotKytkinSortedAndDeduped() {
        make([notes: .init()])
        running = [AppCandidate(bundleID: term, name: "Terminal"), AppCandidate(bundleID: notes, name: "Notes"),
                   AppCandidate(bundleID: own, name: "Kytkin Dev"), AppCandidate(bundleID: chrome, name: "Chrome"),
                   AppCandidate(bundleID: " \(term) ", name: "Terminal again"), AppCandidate(bundleID: " ", name: "x"),
                   AppCandidate(bundleID: "com.example.NoName", name: "")]
        XCTAssertEqual(runningReads, 0, "nothing is read at creation")
        sut.refresh()
        XCTAssertEqual(runningReads, 1)
        XCTAssertEqual(sut.candidates.map(\.bundleID), [chrome, "com.example.NoName", term])
        XCTAssertEqual(sut.candidates[1].name, "com.example.NoName")
    }

    func testAddRunningAppStoresAnEmptyEntryAndLeavesTheMenu() {
        make()
        running = [AppCandidate(bundleID: term, name: "Terminal")]
        sut.refresh()
        XCTAssertTrue(sut.addApp(bundleID: term))
        XCTAssertEqual(apps, [term: .init()])
        XCTAssertEqual(sut.candidates, [])
        XCTAssertEqual(sut.rows.map(\.name), ["Terminal"])
    }

    func testAddKeepsAnExistingEntry() {
        make([notes: .init(disabled: true)])
        XCTAssertTrue(sut.addApp(bundleID: notes))
        XCTAssertEqual(apps[notes], .init(disabled: true))
    }

    func testAddTrimsAndRefusesBlankOrKytkin() {
        make()
        XCTAssertFalse(sut.addApp(bundleID: "  "))
        XCTAssertFalse(sut.addApp(bundleID: own))
        XCTAssertTrue(sut.addApp(bundleID: " \(chrome)\n"))
        XCTAssertEqual(Array(apps.keys), [chrome])
    }

    func testRemoveGoesBackToDefaults() {
        make([notes: .init(disabled: true), term: .init()])
        sut.remove(notes)
        XCTAssertEqual(Array(apps.keys), [term])
        sut.remove("com.example.Missing")
        XCTAssertEqual(Array(apps.keys), [term])
    }

    // MARK: - Read-only

    func testReadOnlyBlocksEveryWrite() {
        let before: [String: Preferences.AppOverride] = [notes: .init(), term: .init(convertEnabled: false)]
        make(before, readOnly: true)
        XCTAssertFalse(sut.isEditable)
        XCTAssertEqual(sut.notices.first?.kind, .readOnly)
        XCTAssertFalse(sut.addApp(bundleID: chrome))
        sut.setKytkinOn(false, for: notes)
        sut.setConvertOn(true, for: term)
        sut.setMethod("keysOnly", for: notes)
        sut.remove(term)
        XCTAssertEqual(apps, before)
        XCTAssertEqual(sut.rows.count, 2, "still listed")
    }

    /// P2-25 QA: opening the tab (refresh, rows, options) never writes, even for a hand-edited terminal method.
    func testReadingTheTabNeverWrites() {
        let before: [String: Preferences.AppOverride] = [notes: .init(), term: .init(replacementMethod: .auto)]
        make(before)
        running = [AppCandidate(bundleID: chrome, name: "Chrome")]
        let changed = WriteSpy()
        withObservationTracking { _ = store.prefs } onChange: { changed.fired = true }
        sut.refresh()
        for row in sut.rows { _ = sut.methodOptions(for: row) }
        _ = sut.emptyText
        XCTAssertFalse(changed.fired)
        XCTAssertEqual(apps, before)
    }

}
