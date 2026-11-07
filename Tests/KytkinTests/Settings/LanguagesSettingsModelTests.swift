// P2-24: Settings → Languages logic: the pair options (turned on, imported, other installed "convert only", input
// methods greyed, a missing saved one), pair validation (A ≠ B, both convertible, not the same keyboard) writing
// `languagePair` only when valid, warnings for the saved pair, import / remove / export with plain messages, and
// read-only mode blocking every change. Fakes only: no panels, no TIS, no real folders.

import XCTest

@MainActor
final class LanguagesSettingsModelTests: XCTestCase {
    private var system: FakeSystemLayouts!
    private var fs: InMemoryLayoutFileSystem!
    private var imported: ImportedLayoutStore!
    private var store: PreferencesStore!
    private var inputMethods: [InputSourceInfo] = []
    private var sut: LanguagesSettingsModel!
    private let picked = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/Downloads/picked.json")
    private let exported = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/Desktop/out.json")
    private let pinyin = InputSourceID("com.apple.inputmethod.SCIM.ITABC")

    private func make(_ prefs: Preferences = Preferences(), store custom: PreferencesStore? = nil) {
        system = FakeSystemLayouts.standard()
        fs = InMemoryLayoutFileSystem()
        imported = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                       fileSystem: fs)
        store = custom ?? makeStore(prefs, clock: FakeClock())
        inputMethods = [InputSourceInfo(id: pinyin, name: "Pinyin - Simplified", languageCode: "zh",
                                        isEnabled: true, isConvertible: false, isInputMethod: true)]
        sut = LanguagesSettingsModel(store: store, imported: imported,
                                     catalog: LayoutMapCatalog(system: system, imported: imported),
                                     fileSystem: fs, inputMethods: { [unowned self] in self.inputMethods })
        sut.refresh()
    }

    private func readOnlyStore() throws -> PreferencesStore {
        let url = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/preferences.json")
        let pfs = InMemoryPreferencesFileSystem(files: [url: try Fixtures.data("preferences/v1-future-version.json")])
        return PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: pfs)
    }

    private func pick(_ fixture: String) throws {
        fs[picked] = try Fixtures.data("layoutmaps/\(fixture)")
    }

    // MARK: - Options

    func testOptionsAreGroupedInOrder() {
        make()
        XCTAssertEqual(sut.options.map(\.id), [IDs.abc, IDs.hebrew, IDs.hebrewQWERTY, pinyin])
        XCTAssertEqual(sut.options.map(\.kind), [.enabled, .enabled, .installed, .inputMethod])
        XCTAssertEqual(sut.options.map(\.title),
                       ["ABC", "Hebrew", "Hebrew-QWERTY (not turned on)", "Pinyin - Simplified (can't convert)"])
        XCTAssertEqual(sut.options.map(\.isSelectable), [true, true, true, false])
        XCTAssertEqual(sut.optionGroups.map(\.title),
                       ["Turned on", "Other installed layouts (convert only)", "Can't convert"])
    }

    func testImportedMapWithAnInstalledBaseIsAnOption() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        let option = try XCTUnwrap(sut.options.first { $0.id == IDs.userHebrew })
        XCTAssertEqual(option.kind, .imported)
        XCTAssertEqual(option.title, "Hebrew (custom) (imported, types with Hebrew)")
        XCTAssertEqual(option.inputSource, IDs.hebrew)
        XCTAssertTrue(option.isSelectable)
        XCTAssertEqual(sut.optionGroups.map(\.title).prefix(2), ["Turned on", "Imported"])
    }

    func testImportedMapWithoutAnInstalledBaseIsNotAnOption() throws {
        make()
        try pick("sample-imported.json")   // no base
        sut.importFile(at: picked)
        XCTAssertNil(sut.options.first { $0.id == IDs.niqqud })
        XCTAssertTrue(sut.exportOptions.contains { $0.id == IDs.niqqud }, "it can still be exported")
    }

    func testAMissingSavedLayoutIsListedNotDropped() {
        var p = Preferences()
        p.languagePair = LanguagePair(a: IDs.abc, b: IDs.russian)
        make(p)
        let last = sut.options.last
        XCTAssertEqual(last?.id, IDs.russian)
        XCTAssertEqual(last?.kind, .missing)
        XCTAssertEqual(last?.title, "Russian (missing)")
        XCTAssertFalse(last?.isSelectable ?? true)
        XCTAssertEqual(sut.pairB, IDs.russian.rawValue, "the picker shows the saved value, not a blank")
        XCTAssertEqual(sut.pairWarnings.count, 1)
        XCTAssertTrue(sut.pairWarnings[0].contains("Russian isn't on this Mac"), sut.pairWarnings[0])
    }

    func testRefreshReadsTheListsAgain() {
        make()
        system.infos.append(FakeSystemLayouts.info(IDs.russian, "Russian"))
        system.maps[IDs.russian] = ConvertFixtures.abc
        XCTAssertFalse(sut.options.contains { $0.id == IDs.russian }, "not before refresh")
        sut.refresh()
        XCTAssertTrue(sut.options.contains { $0.id == IDs.russian })
    }

    // MARK: - Choosing the pair

    func testAValidChoiceIsSaved() {
        make()
        sut.pairB = IDs.hebrewQWERTY.rawValue
        XCTAssertEqual(store.prefs.languagePair, LanguagePair(a: IDs.abc, b: IDs.hebrewQWERTY))
        XCTAssertNil(sut.pairProblem)
        XCTAssertEqual(sut.pairWarnings.count, 1, "not turned on: convert only")
        XCTAssertTrue(sut.pairWarnings[0].contains("can't switch to it"), sut.pairWarnings[0])
    }

    func testTheSameLayoutTwiceIsRefused() {
        make()
        sut.pairA = IDs.hebrew.rawValue
        XCTAssertEqual(store.prefs.languagePair, .default, "nothing written")
        XCTAssertEqual(sut.pairProblem, .sameLanguage)
        XCTAssertEqual(sut.pairProblem?.message, "Choose two different languages.")
    }

    func testAnInputMethodOrUnknownIsRefused() {
        make()
        sut.pairA = pinyin.rawValue
        XCTAssertEqual(sut.pairProblem, .notConvertible("Pinyin - Simplified"))
        sut.pairA = "com.example.nothing"
        XCTAssertEqual(sut.pairProblem, .notConvertible("nothing"))
        XCTAssertEqual(store.prefs.languagePair, .default)
        sut.pairA = IDs.hebrewQWERTY.rawValue
        XCTAssertNil(sut.pairProblem, "a valid choice clears the message")
    }

    func testAnImportedMapAndItsOwnBaseAreRefused() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        sut.pairA = IDs.userHebrew.rawValue        // B is Hebrew, its base
        XCTAssertEqual(sut.pairProblem, .sameKeyboard("Hebrew"))
        XCTAssertEqual(store.prefs.languagePair, .default)
        sut.pairB = IDs.userHebrew.rawValue        // ABC ⇄ Hebrew (custom)
        XCTAssertEqual(store.prefs.languagePair, LanguagePair(a: IDs.abc, b: IDs.userHebrew))
        XCTAssertTrue(sut.pairWarnings.isEmpty)
    }

    func testSwap() {
        make()
        sut.swap()
        XCTAssertEqual(store.prefs.languagePair, LanguagePair(a: IDs.hebrew, b: IDs.abc))
    }

    func testCheckIsPure() {
        let options = LanguagePairOption.options(
            installed: [FakeSystemLayouts.info(IDs.abc, "ABC"), FakeSystemLayouts.info(IDs.hebrew, "")],
            systemIDs: [IDs.abc, IDs.hebrew], inputMethods: [], pair: .default, inputSource: { $0 },
            baseName: { $0.rawValue })
        XCTAssertEqual(options.map(\.title), ["ABC", "Hebrew"], "an empty name falls back to the id's last part")
        XCTAssertNil(LanguagePairProblem.check(.default, options: options, name: { $0.rawValue }))
        XCTAssertEqual(LanguagePairProblem.check(LanguagePair(a: IDs.abc, b: IDs.russian), options: options,
                                                 name: { $0.rawValue }), .notConvertible("Russian"))
    }

    // MARK: - Live effect

    func testAChosenPairReachesTheNextDoubleShift() {
        make()
        let convert = FakeConvert()
        let monitor = FakeContextMonitor()
        let permissions = FakePermissions()
        permissions.statusOnStart = PermissionStatus(grants: PermissionGrants(accessibility: .granted,
                                                                             inputMonitoring: .notDetermined))
        let controller = AppController(switcher: FakeSwitcher(), context: monitor, store: store,
                                       permissions: permissions, conflicts: FakeConflicts(),
                                       keyWatcher: FakeKeyWatcher(), ticker: FakeTicker(), convert: convert,
                                       clock: FakeClock())
        monitor.onChange = { controller.contextDidChange($0) }
        controller.start()
        monitor.activate("com.apple.Notes", pid: 10)
        sut.pairB = IDs.hebrewQWERTY.rawValue
        let snapshot = WordSnapshot(strokes: [], previousWords: [], renderedIn: nil, isValid: true)
        controller.keySignal(.doubleShift(snapshot, gen: 1))
        XCTAssertEqual(convert.requests.map(\.pair), [LanguagePair(a: IDs.abc, b: IDs.hebrewQWERTY)])
        controller.stop()
    }

    // MARK: - Import

    func testImportShowsAPlainSuccessLine() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        XCTAssertEqual(sut.status, .init(text: "Imported “Hebrew (custom)”. You can now choose it as a language.",
                                         isError: false))
        XCTAssertEqual(sut.importedRows, [.init(id: IDs.userHebrew, name: "Hebrew (custom)",
                                                detail: "Changes some keys of Hebrew.", isInPair: false)])
        sut.importFile(at: picked)
        XCTAssertTrue(sut.status?.text.hasPrefix("Updated “Hebrew (custom)”.") ?? false)
    }

    func testImportWithoutABaseSaysWhatItNeeds() throws {
        make()
        try pick("sample-imported.json")
        sut.importFile(at: picked)
        XCTAssertEqual(sut.status?.isError, false)
        XCTAssertTrue(sut.status?.text.contains("needs a \"base\"") ?? false, sut.status?.text ?? "")
        XCTAssertEqual(sut.importedRows.first?.detail,
                       "Full layout. It can't be in the pair: it names no keyboard to type with.")
    }

    func testImportErrorsUseTheLayoutMapMessages() throws {
        make()
        try pick("invalid/string-control-char.json")
        sut.importFile(at: picked)
        let status = try XCTUnwrap(sut.status)
        XCTAssertTrue(status.isError)
        XCTAssertTrue(status.text.hasPrefix("Couldn't import “picked.json”: Key "), status.text)
        XCTAssertTrue(status.text.contains("control character"), status.text)
        try pick("invalid/id-reserved.json")
        sut.importFile(at: picked)
        XCTAssertTrue(sut.status?.text.contains("reserved for Apple") ?? false)
        XCTAssertTrue(fs.writes.isEmpty)
    }

    // MARK: - Remove

    func testRemove() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        sut.remove(IDs.userHebrew)
        XCTAssertEqual(sut.status, .init(text: "Removed “Hebrew (custom)”.", isError: false))
        XCTAssertTrue(sut.importedRows.isEmpty)
    }

    func testAMapInThePairCantBeRemoved() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        sut.pairB = IDs.userHebrew.rawValue
        XCTAssertEqual(sut.importedRows.first?.isInPair, true)
        sut.remove(IDs.userHebrew)
        XCTAssertEqual(sut.status?.isError, true)
        XCTAssertTrue(sut.status?.text.contains("one of your two languages") ?? false)
        XCTAssertEqual(sut.importedRows.count, 1)
    }

    // MARK: - Export

    func testExportASystemLayout() throws {
        make()
        XCTAssertEqual(sut.exportSelection, IDs.abc.rawValue, "defaults to language A")
        XCTAssertEqual(sut.suggestedExportFileName, "com.apple.keylayout.ABC.json")
        sut.exportSelection = IDs.hebrew.rawValue
        sut.export(to: exported)
        let data = try XCTUnwrap(fs[exported])
        XCTAssertEqual(try JSONDecoder().decode(LayoutMap.self, from: data), ConvertFixtures.hebrew)
        XCTAssertThrowsError(try LayoutMap.validate(data), "system maps are export only")
        XCTAssertEqual(sut.status, .init(text: "Exported “Hebrew” to out.json.", isError: false))
    }

    func testAnExportedImportedMapImportsAgain() throws {
        make()
        try pick("sample-user.json")
        sut.importFile(at: picked)
        sut.exportSelection = IDs.userHebrew.rawValue
        sut.export(to: exported)
        XCTAssertEqual(try LayoutMap.validate(XCTUnwrap(fs[exported])), imported.map(for: IDs.userHebrew))
    }

    func testExportFailureIsPlain() {
        make()
        fs.failWrites = true
        sut.export(to: exported)
        XCTAssertEqual(sut.status?.isError, true)
        XCTAssertEqual(sut.status?.text, "Couldn't export “ABC”: Kytkin couldn't write the file there. Try another folder.")
    }

    // MARK: - Read-only (§12 S1)

    func testReadOnlyBlocksEveryChangeAndShowsTheNotice() throws {
        let readOnly = try readOnlyStore()
        make(store: readOnly)
        XCTAssertFalse(sut.isEditable)
        XCTAssertEqual(sut.notices.first?.kind, .readOnly, "the S1 notice")
        let before = store.prefs.languagePair
        sut.pairB = IDs.hebrewQWERTY.rawValue
        sut.swap()
        XCTAssertEqual(store.prefs.languagePair, before)
        try pick("sample-user.json")
        sut.importFile(at: picked)
        XCTAssertTrue(sut.importedRows.isEmpty)
        XCTAssertTrue(fs.writes.isEmpty)
        XCTAssertNil(sut.status)
    }
}
