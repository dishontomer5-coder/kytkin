// P2-24: The real LayoutFileSystem. Foundation only, so it stays in Core. The atomic 0600 write is the one
// PreferencesStore uses (LocalPreferencesFileSystem, 001 §4.1).

import Foundation

struct LocalLayoutFileSystem: LayoutFileSystem {
    init() {}

    /// QA (P2-24): opened non-blocking and checked with `fstat` on the open descriptor, so only a regular file is read
    /// (a FIFO named `x.json` in the layouts folder would otherwise block the main thread forever at launch, and a
    /// device would be read). Not following a symlink here is `jsonFiles`'s job; a file the user picked may be one.
    func contents(of url: URL, maxBytes: Int) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return try handle.read(upToCount: maxBytes + 1) ?? Data()
    }

    func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    /// QA (P2-24): only regular files (checked with `lstat`, which doesn't follow links): a symlink, folder or FIFO
    /// named `x.json` is ignored, so loading never reads, and Remove never deletes, through a link out of the folder.
    func jsonFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" && Self.isRegularFileNotLink($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func isRegularFileNotLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try LocalPreferencesFileSystem().writeAtomically(data, to: url)
    }

    func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
