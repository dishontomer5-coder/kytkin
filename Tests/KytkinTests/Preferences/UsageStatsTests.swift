// P6-0k: Settings → Statistics. The counts (`UsageStats`), how they are stored beside the preferences (decode of old
// files without `stats`, lenient decode, no key until something is counted), the 30 s save debounce (a burst of counts
// is one write; a settings change takes them sooner; quit flushes), reset, read-only (memory only), what the
// SwitchController and the ConvertDispatcher count, and the tab's model (total "1,234", the rows).

import XCTest

@MainActor
final class UsageStatsTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/virtual/Kytkin/preferences.json")
    private let fixedDate = Date(timeIntervalSince1970: 1_793_872_800)   // 2026-11-05T10:00:00Z

    private func makeStore(_ fs: InMemoryPreferencesFileSystem, clock: FakeClock) -> PreferencesStore {
        PreferencesStore(fileURL: fileURL, clock: clock, fileSystem: fs, now: { self.fixedDate })
    }

    private func savedStats(_ fs: InMemoryPreferencesFileSystem) throws -> UsageStats? {
        try PreferencesCodec.decodeDetailed(XCTUnwrap(fs[fileURL])).stats
    }

    private func savedJSON(_ fs: InMemoryPreferencesFileSystem) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fs[fileURL])) as? [String: Any])
    }

    // MARK: - The value

    func testRecordCountsEachKindAndStartsTheDateOnce() {
        var s = UsageStats()
        XCTAssertEqual(s.total, 0)
        XCTAssertNil(s.since)
        s.record(.converted, now: fixedDate)
        s.record(.switchedByApp, now: fixedDate.addingTimeInterval(60))
        s.record(.switchedByApp, now: fixedDate.addingTimeInterval(60))
        s.record(.switchedByWebsite, now: fixedDate.addingTimeInterval(90))
        XCTAssertEqual(s, UsageStats(converted: 1, switchedByApp: 2, switchedByWebsite: 1, since: fixedDate))
        XCTAssertEqual(s.total, 4)
    }

    func testACountNeverWraps() {
        var s = UsageStats(converted: .max)
        s.record(.converted, now: fixedDate)
        XCTAssertEqual(s.converted, .max)
    }

    // MARK: - The file

    func testAnOldFileWithoutStatsDecodesToZero() throws {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try Fixtures.data("preferences/v1-full.json")])
        let store = makeStore(fs, clock: FakeClock())
        XCTAssertEqual(store.stats, UsageStats())
        XCTAssertNil(store.loadIssue)
        XCTAssertFalse(store.loadWasLossy)
        XCTAssertNil(try PreferencesCodec.decodeDetailed(Data("{}".utf8)).stats)
    }

    func testStatsRoundTripAndABadStatsValueIsLenient() throws {
        let stats = UsageStats(converted: 3, switchedByApp: 2, switchedByWebsite: 1, since: fixedDate)
        let data = try PreferencesCodec.encode(Preferences(), stats: stats)
        let decoded = try PreferencesCodec.decodeDetailed(data)
        XCTAssertEqual(decoded.stats, stats)
        XCTAssertEqual(decoded.prefs, Preferences(), "the counts are not a preference")

        let bad = Data(#"{"stats": {"converted": "many", "switchedByApp": -4, "switchedByWebsite": 7, "since": 5}}"#.utf8)
        XCTAssertEqual(try PreferencesCodec.decodeDetailed(bad).stats, UsageStats(switchedByWebsite: 7))
        let notAnObject = Data(#"{"stats": [1, 2]}"#.utf8)
        XCTAssertNil(try PreferencesCodec.decodeDetailed(notAnObject).stats)
    }

    func testNoStatsKeyUntilSomethingIsCounted() throws {
        let data = try PreferencesCodec.encode(Preferences())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["stats"])
    }

    // MARK: - The store: debounce, reset, read-only

    func testACountIsSavedOnlyAfterThirtySecondsAndABurstIsOneWrite() throws {
        let fs = InMemoryPreferencesFileSystem()
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        for _ in 0..<50 { store.recordStat(.converted) }
        XCTAssertEqual(store.stats.converted, 50, "counted in memory at once")
        XCTAssertEqual(store.saveIfDue(), PreferencesStore.statsDebounceNanos)
        clock.advance(byMilliseconds: 29_000)
        store.recordStat(.switchedByApp)   // doesn't push the save back
        XCTAssertEqual(store.saveIfDue(), 1_000_000_000)
        XCTAssertTrue(fs.writes.isEmpty, "no write while typing")
        clock.advance(byMilliseconds: 1_000)
        XCTAssertNil(store.saveIfDue())
        XCTAssertEqual(fs.writes.count, 1)
        XCTAssertEqual(try savedStats(fs), UsageStats(converted: 50, switchedByApp: 1, since: fixedDate))
        let json = try savedJSON(fs)["stats"] as? [String: Any]
        XCTAssertEqual(json?["converted"] as? Int, 50)
        XCTAssertEqual(json?["switchedByApp"] as? Int, 1)
        XCTAssertEqual(json?["switchedByWebsite"] as? Int, 0)
        XCTAssertEqual(json?["since"] as? String, "2026-11-05T10:00:00Z")
    }

    func testASettingsChangeTakesTheCountsWithItSooner() throws {
        let fs = InMemoryPreferencesFileSystem()
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        store.recordStat(.switchedByWebsite)
        store.update { $0.general.enabled = false }
        XCTAssertEqual(store.saveIfDue(), PreferencesStore.debounceNanos)
        clock.advance(byMilliseconds: 500)
        XCTAssertNil(store.saveIfDue())
        XCTAssertEqual(try savedStats(fs)?.switchedByWebsite, 1)
        XCTAssertEqual(fs.writes.count, 1)
    }

    /// QA (P6-0k): a count never delays a settings change already waiting for its 0.5 s save.
    func testACountNeverDelaysAPendingSettingsSave() throws {
        let fs = InMemoryPreferencesFileSystem()
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        store.update { $0.general.enabled = false }
        clock.advance(byMilliseconds: 200)
        for _ in 0..<20 { store.recordStat(.converted) }
        XCTAssertEqual(store.saveIfDue(), 300_000_000, "still the settings deadline")
        clock.advance(byMilliseconds: 300)
        XCTAssertNil(store.saveIfDue())
        XCTAssertEqual(fs.writes.count, 1)
        let saved = try PreferencesCodec.decodeDetailed(XCTUnwrap(fs[fileURL]))
        XCTAssertFalse(saved.prefs.general.enabled)
        XCTAssertEqual(saved.stats?.converted, 20)
    }

    /// QA (P6-0k): a file with counts is neither lossy (no backup) nor read-only, and the counts hold only the four
    /// numbers-and-date keys (no app names, hosts or text).
    func testAFileWithCountsLoadsCleanlyAndHoldsOnlyTheCounts() throws {
        let stats = UsageStats(converted: 4, switchedByApp: 3, switchedByWebsite: 2, since: fixedDate)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try PreferencesCodec.encode(Preferences(), stats: stats)])
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        XCTAssertNil(store.loadIssue)
        XCTAssertFalse(store.loadWasLossy)
        XCTAssertFalse(store.isReadOnly)
        store.recordStat(.switchedByApp)
        clock.advance(byMilliseconds: 30_000)
        store.saveIfDue()
        XCTAssertEqual(fs.writes.count, 1, "the preferences file only, no backup")
        let json = try XCTUnwrap(savedJSON(fs)["stats"] as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["converted", "switchedByApp", "switchedByWebsite", "since"])
        XCTAssertTrue(json.values.allSatisfy { $0 is Int || $0 is String })
        XCTAssertEqual(json["switchedByApp"] as? Int, 4)
    }

    func testQuitFlushesPendingCounts() throws {
        let fs = InMemoryPreferencesFileSystem()
        let store = makeStore(fs, clock: FakeClock())
        store.recordStat(.converted)
        store.flush()
        XCTAssertEqual(try savedStats(fs)?.converted, 1)
    }

    func testCountingNeverChangesThePreferences() {
        let store = makeStore(InMemoryPreferencesFileSystem(), clock: FakeClock())
        let before = store.prefs
        store.recordStat(.converted)
        store.recordStat(.switchedByApp)
        XCTAssertEqual(store.prefs, before)
    }

    func testResetZeroesTheCountsAndStartsAgainNow() throws {
        let stats = UsageStats(converted: 9, switchedByApp: 8, switchedByWebsite: 7,
                               since: Date(timeIntervalSince1970: 0))
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try PreferencesCodec.encode(Preferences(), stats: stats)])
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        XCTAssertEqual(store.stats, stats)
        store.resetStats()
        XCTAssertEqual(store.stats, UsageStats(since: fixedDate))
        clock.advance(byMilliseconds: 30_000)
        store.saveIfDue()
        XCTAssertEqual(try savedStats(fs), UsageStats(since: fixedDate))
    }

    func testReadOnlyCountsInMemoryOnly() throws {
        let newer = Data(#"{"schemaVersion": 99, "stats": {"converted": 2}}"#.utf8)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: newer])
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.stats.converted, 2)
        store.recordStat(.converted)
        XCTAssertEqual(store.stats.converted, 3)
        clock.advance(byMilliseconds: 60_000)
        XCTAssertNil(store.saveIfDue())
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
        XCTAssertEqual(fs[fileURL], newer)
    }

    // MARK: - The tab's model

    func testTheModelFormatsTheTotalAndTheRows() {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try! PreferencesCodec.encode(
            Preferences(), stats: UsageStats(converted: 1_000, switchedByApp: 200, switchedByWebsite: 34))])
        let store = makeStore(fs, clock: FakeClock())
        let model = StatisticsSettingsModel(store: store, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(model.totalText, "1,234")
        XCTAssertEqual(model.rows.map(\.title),
                       ["Converted with Double-Shift", "Switched by app", "Switched by website"])
        XCTAssertEqual(model.rows.map(\.count), ["1,000", "200", "34"])
        model.reset()
        XCTAssertEqual(model.totalText, "0")
        XCTAssertEqual(SettingsTab.statistics.symbolName, "arrow.left.arrow.right")
    }

    // MARK: - What counts

    func testRuleSwitchesCountByKindAndTheUsersOwnDoNot() {
        let clock = FakeClock(nowNanos: 1_000_000_000)
        let switcher = FakeSwitcher(current: IDs.abc)
        let monitor = FakeContextMonitor()
        var p = Preferences()
        p.rules = [.app("com.apple.Notes", IDs.hebrew),
                   Rule(scope: .site(domain: "ynet.co.il"), inputSource: IDs.hebrew, origin: .pinned,
                        updatedAt: fixedDate)]
        let store = makeStore(p, clock: clock)
        let sut = SwitchController(switcher: switcher, context: monitor, store: store, conflicts: FakeConflicts(),
                                   clock: clock, now: { self.fixedDate })
        monitor.onChange = { sut.contextDidChange($0) }

        monitor.activate("com.apple.Notes", pid: 10)                      // app rule: a real change
        XCTAssertEqual(store.stats.switchedByApp, 1)
        monitor.activate("com.apple.Terminal", pid: 11)                   // no rule (keep current)
        switcher.current = IDs.abc                                        // the user's own switch
        sut.inputSourceDidChange(.external(IDs.abc, atNanos: clock.nowNanos + 1_000_000_000))
        monitor.activate("com.apple.Notes", pid: 10)                      // back to Notes: Hebrew again, counted
        XCTAssertEqual(store.stats.switchedByApp, 2)
        monitor.activate("com.apple.Notes", pid: 10)                      // already Hebrew: no change, no count
        XCTAssertEqual(store.stats.switchedByApp, 2)

        switcher.current = IDs.abc
        let site = Context(bundleID: "app.zen-browser.zen", pid: 12, host: "www.ynet.co.il", siteDomain: "ynet.co.il",
                           pageState: .page, generation: 99)
        monitor.current = site
        sut.contextDidChange(site)
        XCTAssertEqual(store.stats.switchedByWebsite, 1)
        XCTAssertEqual(store.stats.converted, 0)
    }

    private func makeStore(_ prefs: Preferences, clock: FakeClock) -> PreferencesStore {
        let fs = InMemoryPreferencesFileSystem()
        if prefs != Preferences() { fs[fileURL] = try? PreferencesCodec.encode(prefs) }
        return PreferencesStore(fileURL: fileURL, clock: clock, fileSystem: fs, now: { self.fixedDate })
    }

    @TextActor private static func setField(_ replacer: ScriptedReplacer) {
        replacer.focus = FocusInfo(role: "AXTextArea", isSecure: false, hasMarkedText: false, selTextSettable: true,
                                   selRangeSettable: true, selection: nil)
    }

    func testOnlyAConvertedDoubleShiftIsCounted() async {
        let log = ConvertLog()
        let watcher = ConvertKeyWatcher(log: log)
        let switches = SwitchRecorder(log: log)
        let maps = FakeLayoutMaps()
        maps.maps = [IDs.abc: ConvertFixtures.abc, IDs.hebrew: ConvertFixtures.hebrew]
        let replacer = ScriptedReplacer(log: log)
        await Self.setField(replacer)
        let controller = ConvertController(keyWatcher: watcher, clock: FakeClock(), beep: {},
                                           makeReplacer: { replacer }, switchLanguage: switches.hook)
        let sut = ConvertDispatcher(controller: controller, maps: maps)
        var counted = 0
        sut.onConverted = { counted += 1 }

        func request(_ gen: UInt64, _ mode: ConvertRequest.Mode, typed: String) -> ConvertRequest {
            let strokes = ConvertFixtures.strokes(typed)
            return ConvertRequest(snapshot: WordSnapshot(strokes: strokes, previousWords: [], renderedIn: IDs.abc,
                                                         isValid: !strokes.isEmpty),
                                  gen: gen, bundleID: "com.apple.TextEdit", mode: mode, pair: ConvertFixtures.pair,
                                  currentSource: IDs.abc, switchAfterConvert: true)
        }
        sut.convert(request(1, .toggleOnly, typed: "akuo"))   // a language toggle
        await sut.lastTask?.value
        sut.convert(request(2, .convert, typed: ""))          // nothing to convert: just switches
        await sut.lastTask?.value
        sut.convert(request(3, .convert, typed: "akuo"))      // converted
        await sut.lastTask?.value
        await Task.yield()
        for _ in 0..<10 where counted == 0 { await Task.yield() }
        XCTAssertEqual(counted, 1)
    }
}
