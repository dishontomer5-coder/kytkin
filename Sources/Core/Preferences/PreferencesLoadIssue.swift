// P2-8: Why PreferencesStore didn't simply load the file (001 §2.2). The menu shows it once
// ("Settings file couldn't be read", 001 §5.1). nil means the file loaded cleanly or didn't exist yet.

import Foundation

enum PreferencesLoadIssue: Sendable, Equatable {
    /// The file had an older schema and was migrated. The original is kept as
    /// `preferences.v<N>.bak.json` on the first save.
    case migrated(from: Int)
    /// The file couldn't be decoded. It was moved here, and the store started from the defaults.
    case corruptQuarantined(URL)
    /// The file comes from a newer Kytkin. It loaded as far as this build understands it, and the
    /// store never writes it (changes stay in memory for this session).
    case newerSchemaReadOnly
    /// The file exists but couldn't be read, or a corrupt file couldn't be moved aside. The store
    /// starts from the defaults and never writes, so nothing on disk is lost.
    case unreadable
}
