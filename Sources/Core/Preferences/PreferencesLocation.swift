// P2-8: Where preferences.json lives (001 §4.1):
//   Release: ~/Library/Application Support/Kytkin/preferences.json
//   Debug (bundle ID io.github.kytkin.Kytkin.dev): ~/Library/Application Support/Kytkin Dev/preferences.json
// The pure `fileURL(applicationSupport:bundleIdentifier:)` is what tests use; only the App layer
// calls `defaultFileURL()`, which looks up the real folder.

import Foundation

enum PreferencesLocation {
    static let fileName = "preferences.json"
    static let releaseFolder = "Kytkin"
    static let debugFolder = "Kytkin Dev"

    /// The Debug app has its own bundle ID, so it never shares a file with a release build (001 §11 Q4).
    static func folderName(bundleIdentifier: String?) -> String {
        bundleIdentifier?.hasSuffix(".dev") == true ? debugFolder : releaseFolder
    }

    static func fileURL(applicationSupport: URL, bundleIdentifier: String?) -> URL {
        applicationSupport
            .appendingPathComponent(folderName(bundleIdentifier: bundleIdentifier), isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The real location for the running app. Never call this from tests.
    static func defaultFileURL(bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: false)
        return fileURL(applicationSupport: support, bundleIdentifier: bundleIdentifier)
    }

    /// `preferences.corrupt-<ISO date>.json` next to the file (colons left out: Finder shows them as "/").
    static func quarantineURL(for fileURL: URL, at date: Date) -> URL {
        let stamp = date.formatted(Date.ISO8601FormatStyle(timeSeparator: .omitted))
        return sibling(of: fileURL, named: "\(baseName(fileURL)).corrupt-\(stamp).json")
    }

    /// `preferences.v<N>.bak.json`, the copy kept before the first migrating write.
    static func backupURL(for fileURL: URL, version: Int) -> URL {
        sibling(of: fileURL, named: "\(baseName(fileURL)).v\(version).bak.json")
    }

    private static func baseName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func sibling(of url: URL, named name: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }
}
