// P2-8: PreferencesStore against an in-memory file system and a temporary directory (never the
// real Application Support folder): first launch, load, migrate + backup, corrupt quarantine,
// newer-schema read-only, debounced save on the injected clock, flush, atomic 0600 writes.

import XCTest

@MainActor
final class PreferencesStoreTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/virtual/Kytkin/preferences.json")
    private let fixedDate = Date(timeIntervalSince1970: 1_793_872_800)   // 2026-11-05T10:00:00Z
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KytkinPreferencesTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore(_ fs: InMemoryPreferencesFileSystem, clock: FakeClock = FakeClock(),
                           migrator: PreferencesMigrator = .standard) -> PreferencesStore {
        PreferencesStore(fileURL: fileURL, clock: clock, fileSystem: fs, migrator: migrator, now: { self.fixedDate })
    }

    private func saved(_ fs: InMemoryPreferencesFileSystem) throws -> Preferences {
        try PreferencesCodec.decodeDetailed(XCTUnwrap(fs[fileURL])).prefs
    }

    // MARK: - Load

    func testFirstLaunchStartsWithDefaultsAndWritesNothing() {
        let fs = InMemoryPreferencesFileSystem()
        let store = makeStore(fs)
        XCTAssertEqual(store.prefs, Preferences())
        XCTAssertNil(store.loadIssue)
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testLoadsAnExistingFile() throws {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try Fixtures.data("preferences/v1-full.json")])
        let store = makeStore(fs)
        XCTAssertNil(store.loadIssue)
        XCTAssertFalse(store.prefs.general.enabled)
        XCTAssertEqual(store.prefs.rules.count, 4)
    }

    func testCorruptFileIsQuarantinedAndDefaultsAreUsed() throws {
        let corrupt = try Fixtures.data("preferences/v1-corrupt.json")
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: corrupt])
        let store = makeStore(fs)
        let expected = URL(fileURLWithPath: "/virtual/Kytkin/preferences.corrupt-2026-11-05T100000Z.json")
        XCTAssertEqual(store.loadIssue, .corruptQuarantined(expected))
        XCTAssertEqual(fs[expected], corrupt, "the corrupt bytes are kept")
        XCTAssertNil(fs[fileURL])
        XCTAssertEqual(store.prefs, Preferences())
        XCTAssertFalse(store.isReadOnly)

        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertFalse(try saved(fs).general.enabled, "a fresh file is written after quarantine")
        XCTAssertEqual(fs[expected], corrupt)
    }

    func testSecondQuarantineInTheSameSecondDoesNotOverwriteTheFirst() throws {
        let first = URL(fileURLWithPath: "/virtual/Kytkin/preferences.corrupt-2026-11-05T100000Z.json")
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: Data("{".utf8), first: Data("older".utf8)])
        let store = makeStore(fs)
        let second = URL(fileURLWithPath: "/virtual/Kytkin/preferences.corrupt-2026-11-05T100000Z-2.json")
        XCTAssertEqual(store.loadIssue, .corruptQuarantined(second))
        XCTAssertEqual(fs[first], Data("older".utf8))
        XCTAssertEqual(fs[second], Data("{".utf8))
    }

    func testCorruptFileThatCannotBeMovedIsLeftAloneAndReadOnly() {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: Data("nope".utf8)])
        fs.failMoves = true
        let store = makeStore(fs)
        XCTAssertEqual(store.loadIssue, .unreadable)
        XCTAssertTrue(store.isReadOnly)
        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertEqual(fs[fileURL], Data("nope".utf8), "never overwritten")
    }

    func testUnreadableFileIsReadOnly() {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: Data("{}".utf8)])
        fs.failReads = true
        let store = makeStore(fs)
        XCTAssertEqual(store.loadIssue, .unreadable)
        XCTAssertTrue(store.isReadOnly)
        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testNewerSchemaIsReadOnlyAndNeverOverwritten() throws {
        let future = try Fixtures.data("preferences/v1-future-version.json")
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: future])
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)
        XCTAssertEqual(store.loadIssue, .newerSchemaReadOnly)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.prefs.convert.doubleShiftSides, .leftOnly)

        store.update { $0.general.enabled = false }
        XCTAssertFalse(store.prefs.general.enabled, "changes apply in memory for the session")
        clock.advance(bySeconds: 5)
        store.saveIfDue()
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
        XCTAssertEqual(fs[fileURL], future)
    }

    // MARK: - Migration

    func testMigratedFileIsBackedUpBeforeTheFirstWrite() throws {
        let chain = PreferencesMigrator(currentVersion: 2, steps: [.init(from: 1) { $0 }])
        let v1 = Data(#"{"schemaVersion":1,"general":{"enabled":false}}"#.utf8)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: v1])
        let store = makeStore(fs, migrator: chain)
        XCTAssertEqual(store.loadIssue, .migrated(from: 1))
        XCTAssertFalse(store.prefs.general.enabled)
        XCTAssertTrue(fs.writes.isEmpty, "nothing is written just by loading")

        store.update { $0.general.learnFromManualSwitches = false }
        store.flush()
        let backup = URL(fileURLWithPath: "/virtual/Kytkin/preferences.v1.bak.json")
        XCTAssertEqual(fs.writes, [backup, fileURL], "backup first, then the migrated file")
        XCTAssertEqual(fs[backup], v1)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(fs[fileURL])) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 2)

        store.update { $0.general.checkForUpdates = false }
        store.flush()
        XCTAssertEqual(fs.writes.filter { $0 == backup }.count, 1, "backed up only once")
    }

    // MARK: - Lossy load (gap 4)

    private var lossyBackup: URL { URL(fileURLWithPath: "/virtual/Kytkin/preferences.lossy-2026-11-05T100000Z.bak.json") }

    func testLossyFileIsCopiedBeforeTheFirstSave() throws {
        let lenient = try Fixtures.data("preferences/v1-lenient.json")
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: lenient])
        let store = makeStore(fs)
        XCTAssertNil(store.loadIssue, "a lossy file still loads")
        XCTAssertTrue(store.loadWasLossy)
        XCTAssertNil(store.originalBackupURL, "nothing copied until a save")
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(fs.writes.isEmpty, "nothing is written just by loading")

        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertEqual(fs.writes, [lossyBackup, fileURL], "backup first, then the file")
        XCTAssertEqual(fs[lossyBackup], lenient, "the original bytes are kept")
        XCTAssertEqual(store.originalBackupURL, lossyBackup)
        XCTAssertTrue(store.loadWasLossy, "stays set for Settings to show")

        store.update { $0.general.checkForUpdates = false }
        store.flush()
        XCTAssertEqual(fs.writes.filter { $0 == lossyBackup }.count, 1, "backed up only once")
    }

    func testCleanFileIsNotBackedUp() throws {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: try Fixtures.data("preferences/v1-full.json")])
        let store = makeStore(fs)
        XCTAssertFalse(store.loadWasLossy)
        store.update { $0.general.enabled = true }
        store.flush()
        XCTAssertEqual(fs.writes, [fileURL])
        XCTAssertNil(store.originalBackupURL)
    }

    func testLossyBackupNeverOverwritesAnEarlierOne() throws {
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: Data(#"{"general":{"enabled":"yes"}}"#.utf8),
                                                       lossyBackup: Data("older".utf8)])
        let store = makeStore(fs)
        store.update { $0.general.enabled = false }
        store.flush()
        let second = URL(fileURLWithPath: "/virtual/Kytkin/preferences.lossy-2026-11-05T100000Z-2.bak.json")
        XCTAssertEqual(fs[lossyBackup], Data("older".utf8))
        XCTAssertEqual(fs[second], Data(#"{"general":{"enabled":"yes"}}"#.utf8))
        XCTAssertEqual(store.originalBackupURL, second)
    }

    func testFailedLossyBackupLeavesTheFileAloneAndRetries() throws {
        let original = Data(#"{"rules":"oops","general":{"enabled":false}}"#.utf8)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: original])
        let store = makeStore(fs)
        XCTAssertTrue(store.loadWasLossy)
        fs.failWritesTo = [lossyBackup]
        store.update { $0.general.checkForUpdates = false }
        store.flush()
        XCTAssertTrue(store.lastSaveFailed)
        XCTAssertEqual(fs[fileURL], original, "not overwritten without a backup")

        fs.failWritesTo = []
        store.flush()
        XCTAssertFalse(store.lastSaveFailed)
        XCTAssertEqual(fs[lossyBackup], original)
        XCTAssertFalse(try saved(fs).general.checkForUpdates)
    }

    func testLossyMigratedFileKeepsOnlyTheVersionBackup() throws {
        let chain = PreferencesMigrator(currentVersion: 2, steps: [.init(from: 1) { $0 }])
        let v1 = Data(#"{"schemaVersion":1,"general":{"enabled":"yes"}}"#.utf8)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: v1])
        let store = makeStore(fs, migrator: chain)
        XCTAssertEqual(store.loadIssue, .migrated(from: 1))
        XCTAssertTrue(store.loadWasLossy)
        store.update { $0.general.enabled = false }
        store.flush()
        let backup = URL(fileURLWithPath: "/virtual/Kytkin/preferences.v1.bak.json")
        XCTAssertEqual(fs.writes, [backup, fileURL], "the .v1.bak already holds the original")
        XCTAssertEqual(store.originalBackupURL, backup)
    }

    func testLossyNewerFileIsStillNeverWritten() throws {
        let future = Data(#"{"schemaVersion":9,"general":{"enabled":"yes"}}"#.utf8)
        let fs = InMemoryPreferencesFileSystem(files: [fileURL: future])
        let store = makeStore(fs)
        XCTAssertEqual(store.loadIssue, .newerSchemaReadOnly)
        XCTAssertTrue(store.loadWasLossy)
        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
    }

    // MARK: - Saving

    func testUpdateSavesAfterTheDebounceOnTheClock() throws {
        let fs = InMemoryPreferencesFileSystem()
        let clock = FakeClock()
        let store = makeStore(fs, clock: clock)

        store.update { $0.general.enabled = false }
        XCTAssertFalse(store.prefs.general.enabled, "applied in memory at once")
        XCTAssertEqual(store.saveIfDue(), 500_000_000)
        XCTAssertTrue(fs.writes.isEmpty)

        clock.advance(byMilliseconds: 300)
        store.update { $0.convert.doubleShiftWindowMs = 250 }   // pushes the deadline out
        clock.advance(byMilliseconds: 300)
        XCTAssertEqual(store.saveIfDue(), 200_000_000)
        XCTAssertTrue(fs.writes.isEmpty)

        clock.advance(byMilliseconds: 200)
        XCTAssertNil(store.saveIfDue())
        XCTAssertEqual(fs.writes, [fileURL])
        let p = try saved(fs)
        XCTAssertFalse(p.general.enabled)
        XCTAssertEqual(p.convert.doubleShiftWindowMs, 250)
        XCTAssertNil(store.saveIfDue(), "nothing pending")
    }

    func testUnchangedUpdateDoesNotSave() {
        let fs = InMemoryPreferencesFileSystem()
        let store = makeStore(fs)
        store.update { $0.general.enabled = true }
        XCTAssertNil(store.saveIfDue())
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testFlushSavesImmediatelyAndOnlyWhenDirty() throws {
        let fs = InMemoryPreferencesFileSystem()
        let store = makeStore(fs)
        store.flush()
        XCTAssertTrue(fs.writes.isEmpty)
        store.update {
            $0.rules.append(Rule(scope: .app(bundleID: "com.apple.Safari"),
                                 inputSource: InputSourceID("com.apple.keylayout.Hebrew"),
                                 origin: .pinned, updatedAt: self.fixedDate))
        }
        store.flush()
        XCTAssertEqual(try saved(fs).rules, store.prefs.rules)
        store.flush()
        XCTAssertEqual(fs.writes.count, 1)
    }

    func testFailedSaveIsReportedAndRetriedByFlush() throws {
        let fs = InMemoryPreferencesFileSystem()
        let store = makeStore(fs)
        fs.failWrites = true
        store.update { $0.general.enabled = false }
        store.flush()
        XCTAssertTrue(store.lastSaveFailed)
        fs.failWrites = false
        store.flush()
        XCTAssertFalse(store.lastSaveFailed)
        XCTAssertFalse(try saved(fs).general.enabled)
    }

    func testDebouncedSaveRunsOnItsOwnWithARealClock() async throws {
        let fs = InMemoryPreferencesFileSystem()
        let store = PreferencesStore(fileURL: fileURL, clock: SystemClock(), fileSystem: fs,
                                     debounceNanos: 20_000_000)
        store.update { $0.general.enabled = false }
        XCTAssertTrue(fs.writes.isEmpty)
        for _ in 0..<200 where fs.writes.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fs.writes, [fileURL])
    }

    // MARK: - Real files (temporary directory only)

    func testRealFileSystemRoundTripWith0600() throws {
        let url = tempDir.appendingPathComponent("Kytkin Dev", isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: LocalPreferencesFileSystem())
        XCTAssertNil(store.loadIssue)
        store.update { $0.convert.doubleShiftSides = .either }
        store.flush()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["preferences.json"], "no temp files left behind")

        let reopened = PreferencesStore(fileURL: url, clock: FakeClock())
        XCTAssertNil(reopened.loadIssue)
        XCTAssertEqual(reopened.prefs.convert.doubleShiftSides, .either)
    }

    func testRealFileSystemReplacesAnExistingFileAndKeeps0600() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let fs = LocalPreferencesFileSystem()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try fs.writeAtomically(Data("new".utf8), to: url)
        XCTAssertEqual(try fs.contents(of: url), Data("new".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRealFileSystemQuarantine() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("preferences.json")
        try Fixtures.data("preferences/v1-corrupt.json").write(to: url)
        let store = PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: LocalPreferencesFileSystem(),
                                     now: { self.fixedDate })
        let q = tempDir.appendingPathComponent("preferences.corrupt-2026-11-05T100000Z.json")
        XCTAssertEqual(store.loadIssue, .corruptQuarantined(q))
        XCTAssertTrue(FileManager.default.fileExists(atPath: q.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRealFileSystemCreatesTheFolderWith0700() throws {
        let dir = tempDir.appendingPathComponent("Kytkin", isDirectory: true)
        try LocalPreferencesFileSystem().writeAtomically(Data("{}".utf8), to: dir.appendingPathComponent("preferences.json"))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testRealFileSystemLossyBackupIs0600AndNoTempFilesRemain() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("preferences.json")
        let original = Data(#"{"general":{"enabled":"yes"}}"#.utf8)
        try original.write(to: url)
        let store = PreferencesStore(fileURL: url, clock: FakeClock(), fileSystem: LocalPreferencesFileSystem(),
                                     now: { self.fixedDate })
        store.update { $0.general.enabled = false }
        store.flush()
        let backup = tempDir.appendingPathComponent("preferences.lossy-2026-11-05T100000Z.bak.json")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: tempDir.path)),
                       ["preferences.json", backup.lastPathComponent])
    }

    func testMissingFileReadsAsNil() throws {
        XCTAssertNil(try LocalPreferencesFileSystem().contents(of: tempDir.appendingPathComponent("none.json")))
    }

    // MARK: - Location

    func testLocationFolders() {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support", isDirectory: true)
        XCTAssertEqual(PreferencesLocation.fileURL(applicationSupport: support, bundleIdentifier: "io.github.kytkin.Kytkin").path,
                       "/Users/x/Library/Application Support/Kytkin/preferences.json")
        XCTAssertEqual(PreferencesLocation.fileURL(applicationSupport: support, bundleIdentifier: "io.github.kytkin.Kytkin.dev").path,
                       "/Users/x/Library/Application Support/Kytkin Dev/preferences.json")
        XCTAssertEqual(PreferencesLocation.folderName(bundleIdentifier: nil), "Kytkin")
    }

    func testBackupAndQuarantineNames() {
        XCTAssertEqual(PreferencesLocation.backupURL(for: fileURL, version: 3).lastPathComponent, "preferences.v3.bak.json")
        XCTAssertEqual(PreferencesLocation.quarantineURL(for: fileURL, at: fixedDate).lastPathComponent,
                       "preferences.corrupt-2026-11-05T100000Z.json")
        XCTAssertEqual(PreferencesLocation.quarantineURL(for: fileURL, at: fixedDate, attempt: 3).lastPathComponent,
                       "preferences.corrupt-2026-11-05T100000Z-3.json")
        XCTAssertEqual(PreferencesLocation.lossyBackupURL(for: fileURL, at: fixedDate).lastPathComponent,
                       "preferences.lossy-2026-11-05T100000Z.bak.json")
    }
}
