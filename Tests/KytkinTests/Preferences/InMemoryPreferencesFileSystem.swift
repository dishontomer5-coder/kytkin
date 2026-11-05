// P2-8: An in-memory PreferencesFileSystem for store tests, with switches to make each operation fail.

import Foundation

final class InMemoryPreferencesFileSystem: PreferencesFileSystem, @unchecked Sendable { // @unchecked: state guarded by `lock`
    struct Failure: Error {}

    private let lock = NSLock()
    private var files: [URL: Data] = [:]
    private var _writes: [URL] = []
    private var _failReads = false
    private var _failWrites = false
    private var _failMoves = false

    init(files: [URL: Data] = [:]) { self.files = files }

    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }
    var failMoves: Bool {
        get { lock.withLock { _failMoves } }
        set { lock.withLock { _failMoves = newValue } }
    }
    /// Every successful write, in order.
    var writes: [URL] { lock.withLock { _writes } }

    subscript(url: URL) -> Data? {
        get { lock.withLock { files[url] } }
        set { lock.withLock { files[url] = newValue } }
    }

    var allURLs: Set<URL> { lock.withLock { Set(files.keys) } }

    func contents(of url: URL) throws -> Data? {
        try lock.withLock {
            if _failReads { throw Failure() }
            return files[url]
        }
    }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { files[url] != nil }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try lock.withLock {
            if _failWrites { throw Failure() }
            files[url] = data
            _writes.append(url)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try lock.withLock {
            if _failMoves { throw Failure() }
            guard files[destination] == nil, let data = files.removeValue(forKey: source) else { throw Failure() }
            files[destination] = data
        }
    }
}
