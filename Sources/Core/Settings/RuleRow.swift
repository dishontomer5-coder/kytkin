// P2-25: One line of Settings → Rules (001 §5.2): what the rule is for, its language, learned or pinned, and when
// it last changed. Built by `RulesSettingsModel` from the winning rule of each scope; the view only lays it out.
// Site and chat rules are Phase 3/4: they are shown if the file has them, but Settings never creates them.

import Foundation

struct RuleRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: RuleScope
    /// "App", "Site", "Site (exact address)", "Chat".
    let kindTitle: String
    /// The app's name (the bundle ID when the app isn't found), the domain or host, or the chat's label.
    let name: String
    /// A second line when it adds something: the bundle ID under a resolved app name, the chat's app.
    let detail: String?
    let inputSource: InputSourceID
    let languageName: String
    let origin: RuleOrigin
    let updatedAt: Date

    var isPinned: Bool { origin == .pinned }
    var originTitle: String { isPinned ? "Pinned" : "Learned" }
}
