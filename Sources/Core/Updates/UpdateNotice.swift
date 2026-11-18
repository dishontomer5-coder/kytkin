// P6-3, P4-3: what the menu shows when a quiet check found a newer Kytkin. A click opens the updater's window.

import Foundation

struct UpdateNotice: Equatable, Sendable {
    let version: String

    /// The menu line.
    var menuTitle: String { "Update available: Kytkin \(version)…" }
}
