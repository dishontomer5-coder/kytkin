// P2-24: The real LayoutFileSystem. Foundation only, so it stays in Core. The atomic 0600 write is the one
// PreferencesStore uses (LocalPreferencesFileSystem, 001 §4.1).

import Foundation

struct LocalLayoutFileSystem: LayoutFileSystem {
    init() {}

    func contents(of url: URL, maxBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes + 1) ?? Data()
    }

    func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    func jsonFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        try LocalPreferencesFileSystem().writeAtomically(data, to: url)
    }

    func removeItem(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
