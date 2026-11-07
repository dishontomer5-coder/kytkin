// P2-24: The file operations the Languages tab needs, behind a protocol (the PreferencesFileSystem pattern, P2-8) so
// tests use an in-memory fake or a temporary directory, never the real Application Support folder.
// Used for three things: the imported maps in `…/Kytkin/layouts/` (001 §4.1), reading a file the user picked to
// import, and writing a file the user picked to export to.

import Foundation

protocol LayoutFileSystem: Sendable {
    /// At most `maxBytes + 1` bytes of the file, so a huge file is never read whole: a result longer than `maxBytes`
    /// means "too large". nil if there is no file. Throws if it exists but can't be read.
    func contents(of url: URL, maxBytes: Int) throws -> Data?
    /// The file's size in bytes, if known (for the "too large" message).
    func size(of url: URL) -> Int?
    /// The `.json` files directly in `directory`, sorted by name. Empty if the folder doesn't exist.
    func jsonFiles(in directory: URL) throws -> [URL]
    /// Replaces `url` atomically with mode 0600; missing parent folders are created with mode 0700.
    func writeAtomically(_ data: Data, to url: URL) throws
    /// Deletes a file. A missing file is not an error.
    func removeItem(at url: URL) throws
}
