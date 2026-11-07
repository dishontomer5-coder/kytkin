// P2-32: LayoutMapCatalog: `map(for:)` is the system map, else the imported one (a `user` map overlaid on its installed
// base, an `imported` map as is); `inputSource(for:)` is the layout itself or the imported map's installed base; the
// listing adds imported maps that can be in the pair. P2-24: ConvertDispatcher resolves an imported pair member to its
// base for switching and converts with the imported map.

import XCTest

/// A system LayoutMapProviding with a layout list (FakeLayoutMaps lists nothing).
@MainActor final class FakeSystemLayouts: LayoutMapProviding {
    var maps: [InputSourceID: LayoutMap] = [:]
    var infos: [InputSourceInfo] = []

    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo] {
        infos.filter { includeDisabled || $0.isEnabled }
    }

    func map(for id: InputSourceID) -> LayoutMap? { maps[id] }

    static func info(_ id: InputSourceID, _ name: String, enabled: Bool = true) -> InputSourceInfo {
        InputSourceInfo(id: id, name: name, languageCode: "", isEnabled: enabled, isConvertible: true,
                        isInputMethod: false)
    }

    /// ABC and Hebrew (turned on), Hebrew-QWERTY (installed, off), with their fixture maps.
    static func standard() -> FakeSystemLayouts {
        let s = FakeSystemLayouts()
        s.maps = [IDs.abc: ConvertFixtures.abc, IDs.hebrew: ConvertFixtures.hebrew,
                  IDs.hebrewQWERTY: ConvertFixtures.map("Hebrew-QWERTY")]
        s.infos = [info(IDs.abc, "ABC"), info(IDs.hebrew, "Hebrew"),
                   info(IDs.hebrewQWERTY, "Hebrew-QWERTY", enabled: false)]
        return s
    }
}

extension IDs {
    static let hebrewQWERTY = InputSourceID("com.apple.keylayout.Hebrew-QWERTY")
    static let userHebrew = InputSourceID("user.he-custom")       // sample-user.json, base Hebrew
    static let niqqud = InputSourceID("user.he-niqqud")           // sample-imported.json, no base
}

@MainActor
final class LayoutMapCatalogTests: XCTestCase {
    private var system: FakeSystemLayouts!
    private var fs: InMemoryLayoutFileSystem!
    private var store: ImportedLayoutStore!
    private var sut: LayoutMapCatalog!
    private let picked = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/picked.json")

    override func setUp() async throws {
        system = FakeSystemLayouts.standard()
        fs = InMemoryLayoutFileSystem()
        store = ImportedLayoutStore(directory: URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts"),
                                    fileSystem: fs)
        sut = LayoutMapCatalog(system: system, imported: store)
    }

    private func importFixture(_ name: String) throws {
        fs[picked] = try Fixtures.data("layoutmaps/\(name)")
        try store.importFile(at: picked)
    }

    func testSystemMapsComeFirst() {
        XCTAssertEqual(sut.map(for: IDs.hebrew), ConvertFixtures.hebrew)
        XCTAssertEqual(sut.inputSource(for: IDs.abc), IDs.abc)
        XCTAssertNil(sut.map(for: IDs.russian))
        XCTAssertNil(sut.inputSource(for: IDs.russian), "not installed")
    }

    func testUserMapIsOverlaidOnItsInstalledBase() throws {
        try importFixture("sample-user.json")
        let map = try XCTUnwrap(sut.map(for: IDs.userHebrew))
        XCTAssertEqual(map.id, IDs.userHebrew)
        XCTAssertEqual(map.keys[25]?.plain, "9", "the override cell")
        XCTAssertEqual(map.keys[0]?.capsLock, "a", "the override cell")
        XCTAssertEqual(map.keys[1]?.plain, ConvertFixtures.hebrew.keys[1]?.plain, "a base cell")
        XCTAssertEqual(sut.inputSource(for: IDs.userHebrew), IDs.hebrew, "Kytkin switches to the base")
        XCTAssertNil(sut.exportMap(for: IDs.userHebrew)?.keys[1], "export writes the stored overrides, not the overlay")
    }

    func testUserMapWithoutItsBaseIsUnavailable() throws {
        try importFixture("sample-user.json")
        system.maps[IDs.hebrew] = nil
        XCTAssertNil(sut.map(for: IDs.userHebrew))
        XCTAssertNil(sut.inputSource(for: IDs.userHebrew))
    }

    func testFullImportedMapConvertsButNeedsABaseToBeInThePair() throws {
        try importFixture("sample-imported.json")
        XCTAssertEqual(sut.map(for: IDs.niqqud)?.keys[38]?.plain, "ח")
        XCTAssertNil(sut.inputSource(for: IDs.niqqud), "no base: nothing to switch to")
        var map = try XCTUnwrap(store.map(for: IDs.niqqud))
        map.base = IDs.hebrew
        try store.add(map)
        XCTAssertEqual(sut.inputSource(for: IDs.niqqud), IDs.hebrew)
        XCTAssertEqual(sut.map(for: IDs.niqqud), map, "a full map is used as is")
    }

    func testListingAddsUsableImportedMaps() throws {
        try importFixture("sample-user.json")
        try importFixture("sample-imported.json")
        let all = sut.convertibleLayouts(includeDisabled: true)
        XCTAssertEqual(all.map(\.id), [IDs.abc, IDs.hebrew, IDs.hebrewQWERTY, IDs.userHebrew])
        XCTAssertEqual(all.last?.name, "Hebrew (custom)")
        XCTAssertEqual(all.last?.isEnabled, true, "its base is turned on")
        system.infos[1] = FakeSystemLayouts.info(IDs.hebrew, "Hebrew", enabled: false)
        XCTAssertEqual(sut.convertibleLayouts(includeDisabled: false).map(\.id), [IDs.abc])
    }

    // MARK: - ConvertDispatcher with an imported pair member

    func testDispatcherSnapshotConvertsWithTheImportedMapUnderTheBaseID() throws {
        try importFixture("sample-user.json")
        let log = ConvertLog()
        let replacer = ScriptedReplacer(log: log)
        let controller = ConvertController(keyWatcher: ConvertKeyWatcher(log: log), clock: FakeClock(),
                                           beep: { log.add(.beep) }, makeReplacer: { replacer },
                                           switchLanguage: SwitchRecorder(log: log).hook)
        let dispatcher = ConvertDispatcher(controller: controller, maps: sut)
        let stored = LanguagePair(a: IDs.abc, b: IDs.userHebrew)
        let snapshot = try XCTUnwrap(dispatcher.snapshot(for: stored))
        XCTAssertEqual(snapshot.pair, LanguagePair(a: IDs.abc, b: IDs.hebrew), "answers are input sources")
        // Key 25 types "9" in the override (Hebrew types it too); key 0 (a) gives the override's "ש".
        XCTAssertEqual(snapshot.render(ConvertFixtures.strokes("a"), from: IDs.abc)?.text, "ש")
        XCTAssertNil(dispatcher.snapshot(for: LanguagePair(a: IDs.hebrew, b: IDs.userHebrew)),
                     "both type with Hebrew: nothing to convert between")
    }

    func testDispatcherToggleSwitchesToTheImportedMapsBase() async throws {
        try importFixture("sample-user.json")
        let log = ConvertLog()
        let replacer = ScriptedReplacer(log: log)
        let controller = ConvertController(keyWatcher: ConvertKeyWatcher(log: log), clock: FakeClock(),
                                           beep: { log.add(.beep) }, makeReplacer: { replacer },
                                           switchLanguage: SwitchRecorder(log: log).hook)
        let dispatcher = ConvertDispatcher(controller: controller, maps: sut)
        dispatcher.convert(ConvertRequest(
            snapshot: WordSnapshot(strokes: [], previousWords: [], renderedIn: IDs.abc, isValid: false),
            gen: 1, bundleID: "com.apple.TextEdit", mode: .toggleOnly,
            pair: LanguagePair(a: IDs.abc, b: IDs.userHebrew), currentSource: IDs.abc, switchAfterConvert: true))
        await dispatcher.lastTask?.value
        XCTAssertEqual(log.entries, [.switchTo(IDs.hebrew, keepsBuffer: false),
                                     .finish(gen: 1, newRendering: nil, bufferAfter: nil)])
    }
}
