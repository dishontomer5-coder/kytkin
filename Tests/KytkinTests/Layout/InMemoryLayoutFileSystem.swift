// P2-24: An in-memory LayoutFileSystem for the import store and Languages tab tests, with switches to make reads,
// writes and deletes fail. Never touches the disk.

import Foundation

final class InMemoryLayoutFileSystem: LayoutFileSystem, @unchecked Sendable { // @unchecked: state guarded by `lock`
    struct Failure: Error {}

    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var _failReads = false
    private var _failWrites = false
    private var _failRemoves = false
    private var _writes: [URL] = []
    private var _largestRead = 0

    init(files: [URL: Data] = [:]) { self.files = files }

    subscript(url: URL) -> Data? {
        get { lock.withLock { files[url] } }
        set { lock.withLock { files[url] = newValue } }
    }

    var allURLs: Set<URL> { lock.withLock { Set(files.keys) } }
    var writes: [URL] { lock.withLock { _writes } }
    /// The most bytes any single read returned (the cap test checks a big file is never read whole).
    var largestRead: Int { lock.withLock { _largestRead } }

    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }
    var failRemoves: Bool {
        get { lock.withLock { _failRemoves } }
        set { lock.withLock { _failRemoves = newValue } }
    }

    func contents(of url: URL, maxBytes: Int) throws -> Data? {
        try lock.withLock {
            if _failReads { throw Failure() }
            guard let data = files[url] else { return nil }
            let read = data.prefix(maxBytes + 1)
            _largestRead = max(_largestRead, read.count)
            return Data(read)
        }
    }

    func size(of url: URL) -> Int? {
        lock.withLock { files[url]?.count }
    }

    func jsonFiles(in directory: URL) throws -> [URL] {
        lock.withLock {
            files.keys
                .filter { $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
                    && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if _failWrites { throw Failure() }
            files[url] = data
            _writes.append(url)
        }
    }

    func removeItem(at url: URL) throws {
        try lock.withLock {
            if _failRemoves { throw Failure() }
            files[url] = nil
        }
    }
}
