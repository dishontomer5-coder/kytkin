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
    private var _failWritesTo: Set<URL> = []
    private var _failPermissions = false
    private var _ownerOnly: Set<URL> = []

    init(files: [URL: Data] = [:]) { self.files = files }

    var failReads: Bool {
        get { lock.withLock { _failReads } }
        set { lock.withLock { _failReads = newValue } }
    }
    var failWrites: Bool {
        get { lock.withLock { _failWrites } }
        set { lock.withLock { _failWrites = newValue } }
    }
    /// Writes to just these URLs fail.
    var failWritesTo: Set<URL> {
        get { lock.withLock { _failWritesTo } }
        set { lock.withLock { _failWritesTo = newValue } }
    }
    var failMoves: Bool {
        get { lock.withLock { _failMoves } }
        set { lock.withLock { _failMoves = newValue } }
    }
    /// P2-37: makes `setOwnerOnlyPermissions` throw.
    var failPermissions: Bool {
        get { lock.withLock { _failPermissions } }
        set { lock.withLock { _failPermissions = newValue } }
    }
    /// P2-37: files a successful `setOwnerOnlyPermissions` was called on (a moved file loses the mark).
    var ownerOnlyURLs: Set<URL> { lock.withLock { _ownerOnly } }
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
            if _failWrites || _failWritesTo.contains(url) { throw Failure() }
            files[url] = data
            _writes.append(url)
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try lock.withLock {
            if _failMoves { throw Failure() }
            guard files[destination] == nil, let data = files.removeValue(forKey: source) else { throw Failure() }
            files[destination] = data
            _ownerOnly.remove(source)
        }
    }

    func setOwnerOnlyPermissions(at url: URL) throws {
        try lock.withLock {
            if _failPermissions || files[url] == nil { throw Failure() }
            _ownerOnly.insert(url)
        }
    }
}
