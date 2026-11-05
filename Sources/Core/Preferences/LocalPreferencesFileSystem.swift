// P2-8: The real PreferencesFileSystem (001 §4.1: atomic write, mode 0600). Foundation only, so it
// stays in Core. The new file is written next to the target, set to 0600, then renamed over it,
// so the final file is never readable by others, not even for a moment.

import Foundation

struct LocalPreferencesFileSystem: PreferencesFileSystem {
    init() {}

    func contents(of url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
            }
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            // createFile's mode is filtered by the umask; set it again explicitly.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            guard rename(temp.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
