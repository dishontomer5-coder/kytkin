// P2-24: The layout maps the user imported, kept as files in `…/Kytkin/layouts/<id>.json` next to preferences.json
// (Debug: `Kytkin Dev/layouts/`, 001 §4.1). System maps are never written here: they are rebuilt at runtime.
//
// - Import: the picked file is read with the 256 KB cap (never read whole), then `LayoutMap.validate` applies every
//   import rule (P2-5, P2-30: control characters, `system` source rejected, ids `[A-Za-z0-9._-]` ≤ 64 with the
//   `user.` prefix). The file is stored re-encoded (`jsonData()`), so the stored id is the final, prefixed one.
//   Importing an id that is already there replaces it.
// - Files are written atomically with mode 0600 (folder 0700) through `LayoutFileSystem`.
// - Loading checks every stored file again with the same rules; a file that fails is skipped (and named in Settings),
//   never deleted.

import Foundation
import Observation

@MainActor @Observable final class ImportedLayoutStore {
    /// One stored map and the file it came from (removing deletes that file).
    struct Entry: Equatable, Sendable {
        let map: LayoutMap
        let fileURL: URL
    }

    enum ImportResult: Equatable, Sendable {
        case added(LayoutMap)
        case replaced(LayoutMap)

        var map: LayoutMap {
            switch self {
            case .added(let m), .replaced(let m): m
            }
        }
    }

    nonisolated static let folderName = "layouts"

    /// `…/Kytkin/layouts/` for `…/Kytkin/preferences.json`.
    nonisolated static func directory(forPreferencesFile fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
    }

    @ObservationIgnored let directory: URL
    @ObservationIgnored let fileSystem: any LayoutFileSystem

    /// Sorted by name, then id.
    private(set) var entries: [Entry] = []
    /// File names in the folder that didn't load (unreadable, or not a valid layout map).
    private(set) var skippedFiles: [String] = []

    var maps: [LayoutMap] { entries.map(\.map) }

    init(directory: URL, fileSystem: any LayoutFileSystem) {
        self.directory = directory
        self.fileSystem = fileSystem
        reload()
    }

    func map(for id: InputSourceID) -> LayoutMap? {
        entries.first { $0.map.id == id }?.map
    }

    /// Reads the folder again.
    func reload() {
        var loaded: [Entry] = []
        var skipped: [String] = []
        var seen = Set<InputSourceID>()
        let files = (try? fileSystem.jsonFiles(in: directory)) ?? []
        for url in files {
            guard let data = try? fileSystem.contents(of: url, maxBytes: LayoutMap.maxFileBytes),
                  let map = try? LayoutMap.validate(data), seen.insert(map.id).inserted else {
                skipped.append(url.lastPathComponent)
                continue
            }
            loaded.append(Entry(map: map, fileURL: url))
        }
        entries = Self.sorted(loaded)
        skippedFiles = skipped
    }

    /// Reads, checks and stores the file the user picked.
    @discardableResult func importFile(at url: URL) throws(LayoutImportError) -> ImportResult {
        let data: Data
        do {
            guard let read = try fileSystem.contents(of: url, maxBytes: LayoutMap.maxFileBytes) else {
                throw LayoutImportError.unreadable
            }
            data = read
        } catch {
            throw .unreadable
        }
        if data.count > LayoutMap.maxFileBytes {
            throw .invalid(.fileTooLarge(bytes: fileSystem.size(of: url) ?? data.count))
        }
        let map: LayoutMap
        do {
            map = try LayoutMap.validate(data)
        } catch let error as LayoutMapError {
            throw .invalid(error)
        } catch {
            throw .unreadable
        }
        return try add(map)
    }

    /// Stores an already validated map (re-encoded, so it loads back with the same id).
    @discardableResult func add(_ map: LayoutMap) throws(LayoutImportError) -> ImportResult {
        // P2-30: system maps are export only; `jsonData()` alone would encode one.
        guard map.source != .system else { throw .invalid(.systemSourceImport) }
        let encoded: Data
        do {
            encoded = try map.jsonData()
        } catch let error as LayoutMapError {
            throw .invalid(error)
        } catch {
            throw .saveFailed
        }
        let existing = entries.first { $0.map.id == map.id }
        guard let url = existing?.fileURL ?? fileURL(for: map.id) else {
            throw .invalid(.invalidIDCharacters(map.id.rawValue))
        }
        do {
            try fileSystem.writeAtomically(encoded, to: url)
        } catch {
            throw .saveFailed
        }
        var updated = entries.filter { $0.map.id != map.id }
        updated.append(Entry(map: map, fileURL: url))
        entries = Self.sorted(updated)
        return existing == nil ? .added(map) : .replaced(map)
    }

    func remove(id: InputSourceID) throws(LayoutImportError) {
        guard let entry = entries.first(where: { $0.map.id == id }) else { return }
        do {
            try fileSystem.removeItem(at: entry.fileURL)
        } catch {
            throw .saveFailed
        }
        entries.removeAll { $0.map.id == id }
    }

    /// `<id>.json` in the layouts folder. Validated ids are only `[A-Za-z0-9._-]` and start with `user.`, so the
    /// name can't leave the folder or be hidden; checked again here anyway.
    /// nil for an id that isn't a safe file name.
    func fileURL(for id: InputSourceID) -> URL? {
        let raw = id.rawValue
        guard !raw.isEmpty, !raw.hasPrefix("."), raw.count <= LayoutMap.maxIDLength,
              raw.unicodeScalars.allSatisfy(LayoutMap.isAllowedIDScalar) else { return nil }
        return directory.appendingPathComponent(raw + ".json", isDirectory: false)
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            let a = $0.map.name.localizedStandardCompare($1.map.name)
            return a == .orderedSame ? $0.map.id.rawValue < $1.map.id.rawValue : a == .orderedAscending
        }
    }
}
