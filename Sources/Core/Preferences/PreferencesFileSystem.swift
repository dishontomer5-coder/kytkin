// P2-8: The few file operations PreferencesStore needs, behind a protocol so tests can use an
// in-memory fake or a temporary directory, and never the real Application Support folder.

import Foundation

protocol PreferencesFileSystem: Sendable {
    /// The file's bytes, or nil if there is no file. Throws if it exists but can't be read.
    func contents(of url: URL) throws -> Data?
    func fileExists(at url: URL) -> Bool
    /// Replaces `url` atomically, so a crash leaves either the old or the new file, never half of one.
    /// The file gets mode 0600, and missing parent folders are created (mode 0700).
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Renames a file. Fails if `destination` exists.
    func moveItem(at source: URL, to destination: URL) throws
}
