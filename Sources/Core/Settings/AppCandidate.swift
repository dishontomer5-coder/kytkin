// P2-25: An app the user can add in Settings → Apps: one of the running apps, or one chosen in /Applications.
// Only the bundle ID is stored (design.md: persist only bundle IDs); the name is for the list.

import Foundation

struct AppCandidate: Identifiable, Equatable, Sendable {
    let bundleID: String
    let name: String

    var id: String { bundleID }
}
