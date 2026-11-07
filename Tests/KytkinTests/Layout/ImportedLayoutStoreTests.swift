// P2-24: ImportedLayoutStore: every invalid fixture is refused with its LayoutMapError and nothing is written, the
// size cap (a big file is never read whole), ids get `user.` and become `<id>.json` in `layouts/`, re-import
// replaces, remove deletes, reload re-checks files (bad ones are skipped, never deleted). The real file system is
// used only in a temporary directory (mode 0600 / 0700).

import XCTest

@MainActor
final class ImportedLayoutStoreTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/layouts", isDirectory: true)
    private let picked = URL(fileURLWithPath: "/tmp/kytkin-tests-never-written/Downloads/picked.json")
    private var fs: InMemoryLayoutFileSystem!
    private var sut: ImportedLayoutStore!

    override func setUp() async throws {
        fs = InMemoryLayoutFileSystem()
        sut = ImportedLayoutStore(directory: dir, fileSystem: fs)
    }

    private func pick(_ fixture: String) throws {
        fs[picked] = try Fixtures.data("layoutmaps/\(fixture)")
    }

    private func importError(_ body: () throws -> Void) -> LayoutImportError? {
        do { try body() } catch let error as LayoutImportError { return error } catch { XCTFail("\(error)") }
        return nil
    }

    // MARK: - Location

    func testDirectoryIsNextToThePreferencesFile() {
        let prefs = URL(fileURLWithPath: "/Users/x/Library/Application Support/Kytkin Dev/preferences.json")
        XCTAssertEqual(ImportedLayoutStore.directory(forPreferencesFile: prefs).path,
                       "/Users/x/Library/Application Support/Kytkin Dev/layouts")
    }

    func testCreatingTheStoreWritesNothing() {
        XCTAssertTrue(fs.writes.isEmpty)
        XCTAssertTrue(sut.entries.isEmpty)
        XCTAssertTrue(sut.skippedFiles.isEmpty)
    }

    // MARK: - Import

    func testImportsAUserMapAsItsIDFile() throws {
        try pick("sample-user.json")
        let result = try sut.importFile(at: picked)
        guard case .added(let map) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(map.id, InputSourceID("user.he-custom"))
        let file = dir.appendingPathComponent("user.he-custom.json")
        XCTAssertEqual(fs.writes, [file])
        XCTAssertEqual(try LayoutMap.validate(XCTUnwrap(fs[file])), map, "the stored file loads back the same")
        XCTAssertEqual(sut.map(for: map.id), map)
    }

    func testImportedIDGetsTheUserPrefix() throws {
        try pick("sample-imported.json")
        let map = try sut.importFile(at: picked).map
        XCTAssertEqual(map.id, InputSourceID("user.he-niqqud"))
        XCTAssertNotNil(fs[dir.appendingPathComponent("user.he-niqqud.json")], "file name uses the final id")
        let stored = try String(decoding: XCTUnwrap(fs[dir.appendingPathComponent("user.he-niqqud.json")]),
                                as: UTF8.self)
        XCTAssertTrue(stored.contains("\"user.he-niqqud\""))
        XCTAssertFalse(stored.contains("futureField"), "stored re-encoded, not as the raw file")
    }

    func testEveryInvalidFixtureIsRefusedWithItsErrorAndNothingIsWritten() throws {
        let folder = try Fixtures.url("layoutmaps/invalid")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(names.count, 30)
        for name in names.sorted() {
            let data = try Fixtures.data("layoutmaps/invalid/\(name)")
            var expected: LayoutMapError?
            do { _ = try LayoutMap.validate(data) } catch let e as LayoutMapError { expected = e }
            let want = try XCTUnwrap(expected, "\(name) should be invalid")
            fs[picked] = data
            let error = importError { _ = try sut.importFile(at: picked) }
            XCTAssertEqual(error, .invalid(want), name)
            XCTAssertFalse(error?.message.isEmpty ?? true, name)
        }
        XCTAssertTrue(fs.writes.isEmpty)
        XCTAssertTrue(sut.entries.isEmpty)
    }

    func testControlCharacterAndSystemSourceMessagesArePlain() throws {
        try pick("invalid/string-control-char.json")
        let control = importError { _ = try sut.importFile(at: picked) }
        XCTAssertTrue(control?.message.contains("control character") ?? false, "\(String(describing: control))")
        try pick("invalid/source-system.json")
        let system = importError { _ = try sut.importFile(at: picked) }
        XCTAssertEqual(system, .invalid(.systemSourceImport))
    }

    func testABigFileIsRefusedWithoutReadingItWhole() {
        fs[picked] = Data(repeating: 0x20, count: 5_000_000)
        let error = importError { _ = try sut.importFile(at: picked) }
        XCTAssertEqual(error, .invalid(.fileTooLarge(bytes: 5_000_000)))
        XCTAssertLessThanOrEqual(fs.largestRead, LayoutMap.maxFileBytes + 1)
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testMissingOrUnreadableFile() {
        XCTAssertEqual(importError { _ = try sut.importFile(at: picked) }, .unreadable)
        fs[picked] = Data("{}".utf8)
        fs.failReads = true
        XCTAssertEqual(importError { _ = try sut.importFile(at: picked) }, .unreadable)
    }

    func testReimportReplacesTheSameFile() throws {
        try pick("sample-user.json")
        try sut.importFile(at: picked)
        var map = try XCTUnwrap(sut.map(for: InputSourceID("user.he-custom")))
        map.name = "Hebrew (mine)"
        fs[picked] = try map.jsonData()
        let result = try sut.importFile(at: picked)
        XCTAssertEqual(result, .replaced(map))
        XCTAssertEqual(sut.entries.count, 1)
        XCTAssertEqual(Set(fs.writes), [dir.appendingPathComponent("user.he-custom.json")])
    }

    func testAFailedWriteKeepsNothing() throws {
        try pick("sample-user.json")
        fs.failWrites = true
        XCTAssertEqual(importError { _ = try sut.importFile(at: picked) }, .saveFailed)
        XCTAssertTrue(sut.entries.isEmpty)
    }

    func testAddRefusesASystemMap() {
        let map = LayoutMap(id: InputSourceID("user.x"), name: "X", language: "en", source: .system)
        XCTAssertEqual(importError { _ = try sut.add(map) }, .invalid(.systemSourceImport))
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testFileURLOnlyForSafeIDs() {
        XCTAssertEqual(sut.fileURL(for: InputSourceID("user.a-b_c.1"))?.lastPathComponent, "user.a-b_c.1.json")
        XCTAssertNil(sut.fileURL(for: InputSourceID("user./../x")))
        XCTAssertNil(sut.fileURL(for: InputSourceID(".hidden")))
        XCTAssertNil(sut.fileURL(for: InputSourceID("")))
        XCTAssertNil(sut.fileURL(for: InputSourceID("user." + String(repeating: "a", count: 60))))
    }

    // MARK: - Remove and reload

    func testRemoveDeletesTheFile() throws {
        try pick("sample-user.json")
        try sut.importFile(at: picked)
        try sut.remove(id: InputSourceID("user.he-custom"))
        XCTAssertTrue(sut.entries.isEmpty)
        XCTAssertNil(fs[dir.appendingPathComponent("user.he-custom.json")])
        XCTAssertNoThrow(try sut.remove(id: InputSourceID("user.nothing")), "unknown id: nothing to do")
    }

    func testAFailedRemoveKeepsTheEntry() throws {
        try pick("sample-user.json")
        try sut.importFile(at: picked)
        fs.failRemoves = true
        XCTAssertEqual(importError { try sut.remove(id: InputSourceID("user.he-custom")) }, .saveFailed)
        XCTAssertEqual(sut.entries.count, 1)
    }

    func testReloadChecksEveryFileAndSkipsBadOnesWithoutDeleting() throws {
        fs[dir.appendingPathComponent("user.he-custom.json")] = try Fixtures.data("layoutmaps/sample-user.json")
        fs[dir.appendingPathComponent("bad.json")] = try Fixtures.data("layoutmaps/invalid/string-control-char.json")
        fs[dir.appendingPathComponent("system.json")] = try Fixtures.data("layoutmaps/sample-system.json")
        fs[dir.appendingPathComponent("notes.txt")] = Data("hi".utf8)
        // Same id twice (hand-copied file): the first by name wins, the second is skipped.
        fs[dir.appendingPathComponent("zz-copy.json")] = try Fixtures.data("layoutmaps/sample-user.json")
        sut.reload()
        XCTAssertEqual(sut.maps.map(\.id), [InputSourceID("user.he-custom")])
        XCTAssertEqual(sut.skippedFiles, ["bad.json", "system.json", "zz-copy.json"])
        XCTAssertNotNil(fs[dir.appendingPathComponent("bad.json")], "never deleted")
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testEntriesAreSortedByName() throws {
        try pick("sample-user.json")            // "Hebrew (custom)"
        try sut.importFile(at: picked)
        try pick("sample-imported.json")        // "Hebrew with niqqud (imported)"
        try sut.importFile(at: picked)
        let a = LayoutMap(id: InputSourceID("user.a"), name: "Arabic (mine)", language: "ar", source: .imported,
                          keys: [0: KeyCell(plain: "ش")])
        try sut.add(a)
        XCTAssertEqual(sut.maps.map(\.name), ["Arabic (mine)", "Hebrew (custom)", "Hebrew with niqqud (imported)"])
    }

    // MARK: - QA (P2-24): hostile ids and files

    private func mapJSON(id: String) -> Data {
        Data("""
        {"format":"kytkin-layoutmap","version":1,"id":"\(id)","name":"N","language":"he","source":"user",
         "base":"com.apple.keylayout.Hebrew","keys":{"0":{"plain":"ש"}}}
        """.utf8)
    }

    func testIDsThatCouldLeaveTheFolderOrHideAreRefusedAndNothingIsWritten() {
        for id in ["../evil", "user./../x", "a/b", "user.he\u{0301}", "\u{FF55}ser.x", "user.\u{2215}x", "/etc/x",
                   "user.x y"] {
            fs[picked] = mapJSON(id: id)
            guard case .invalid(.invalidIDCharacters) = importError({ _ = try sut.importFile(at: picked) }) else {
                return XCTFail(id)
            }
        }
        XCTAssertTrue(fs.writes.isEmpty)
    }

    func testAnIDDifferingOnlyInCaseIsRefusedNotStoredOverTheOther() throws {
        fs[picked] = mapJSON(id: "user.Foo")
        try sut.importFile(at: picked)
        fs[picked] = mapJSON(id: "user.foo")
        XCTAssertEqual(importError { _ = try sut.importFile(at: picked) }, .idDiffersOnlyInCase(existingName: "N"))
        XCTAssertEqual(sut.maps.map(\.id), [InputSourceID("user.Foo")])
        XCTAssertEqual(fs.writes, [dir.appendingPathComponent("user.Foo.json")], "the second is never written")
        // The same id again is still a plain replace.
        fs[picked] = mapJSON(id: "user.Foo")
        XCTAssertEqual(try sut.importFile(at: picked).map.id, InputSourceID("user.Foo"))
    }

    func testReloadLoadsOneOfTwoFilesWhoseIDsDifferOnlyInCase() {
        fs[dir.appendingPathComponent("a.json")] = mapJSON(id: "user.Foo")
        fs[dir.appendingPathComponent("b.json")] = mapJSON(id: "user.FOO")
        sut.reload()
        XCTAssertEqual(sut.maps.map(\.id), [InputSourceID("user.Foo")])
        XCTAssertEqual(sut.skippedFiles, ["b.json"])
    }

    func testLocalFileSystemIgnoresLinksFoldersAndFIFOsAndRemoveDeletesOnlyThatFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kytkin-p2-24-\(UUID().uuidString)", isDirectory: true)
        let layouts = root.appendingPathComponent("layouts", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: layouts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A valid map outside, linked in; a folder and a FIFO named like maps; two real maps.
        let target = outside.appendingPathComponent("target.json")
        try mapJSON(id: "user.linked").write(to: target)
        let link = layouts.appendingPathComponent("user.linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createDirectory(at: layouts.appendingPathComponent("folder.json"),
                                                withIntermediateDirectories: false)
        let fifo = layouts.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try mapJSON(id: "user.real").write(to: layouts.appendingPathComponent("user.real.json"))
        try mapJSON(id: "user.other").write(to: layouts.appendingPathComponent("user.other.json"))

        let local = LocalLayoutFileSystem()
        XCTAssertEqual(try local.jsonFiles(in: layouts).map(\.lastPathComponent), ["user.other.json", "user.real.json"])
        XCTAssertThrowsError(try local.contents(of: fifo, maxBytes: 10), "a FIFO is refused, not waited on")
        XCTAssertThrowsError(try local.contents(of: layouts.appendingPathComponent("folder.json"), maxBytes: 10))
        XCTAssertEqual(try local.contents(of: link, maxBytes: 10)?.count, 11, "a picked file may be a link")

        let store = ImportedLayoutStore(directory: layouts, fileSystem: local)
        XCTAssertEqual(store.maps.map(\.id), [InputSourceID("user.other"), InputSourceID("user.real")])
        XCTAssertNil(store.map(for: InputSourceID("user.linked")))
        try store.remove(id: InputSourceID("user.real"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layouts.appendingPathComponent("user.real.json").path))
        for kept in ["user.other.json", "folder.json", "fifo.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: layouts.appendingPathComponent(kept).path), kept)
        }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))

        // Importing a map whose file name is the link's replaces the link with a file in the folder; the target
        // outside is never written.
        var other = try XCTUnwrap(store.map(for: InputSourceID("user.other")))
        other.id = InputSourceID("user.linked")
        try store.add(other)
        XCTAssertEqual(try Data(contentsOf: target), mapJSON(id: "user.linked"), "the link's target is untouched")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "now a plain file")
    }

    // MARK: - The real file system, in a temporary directory only

    func testLocalFileSystemWritesOwnerOnlyAndReadsCapped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kytkin-p2-24-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = LocalLayoutFileSystem()
        let layouts = root.appendingPathComponent("layouts", isDirectory: true)
        let store = ImportedLayoutStore(directory: layouts, fileSystem: local)
        XCTAssertTrue(store.entries.isEmpty, "a missing folder is just empty")

        let source = root.appendingPathComponent("picked.json")
        try Fixtures.data("layoutmaps/sample-user.json").write(to: source)
        try store.importFile(at: source)
        let file = layouts.appendingPathComponent("user.he-custom.json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: layouts.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(dirMode?.intValue, 0o700)
        XCTAssertEqual(try local.jsonFiles(in: layouts).map(\.lastPathComponent), ["user.he-custom.json"])

        let again = ImportedLayoutStore(directory: layouts, fileSystem: local)
        XCTAssertEqual(again.maps, store.maps, "loads back after a restart")

        let big = root.appendingPathComponent("big.json")
        try Data(repeating: 0x20, count: 400_000).write(to: big)
        XCTAssertEqual(try local.contents(of: big, maxBytes: 1000)?.count, 1001)
        XCTAssertEqual(local.size(of: big), 400_000)
        XCTAssertEqual(importError { _ = try store.importFile(at: big) }, .invalid(.fileTooLarge(bytes: 400_000)))

        try store.remove(id: InputSourceID("user.he-custom"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
