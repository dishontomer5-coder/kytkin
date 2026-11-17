// P2-25: Settings → Rules "Show": all rules, only learned ones, or only pinned ones.
// P6-0g (design v2, P2): the menu's words, "Always" and "Learned"; "All Rules" (lg-rules).

import Foundation

enum RuleOriginFilter: String, CaseIterable, Identifiable, Sendable {
    case all, learned, pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Rules"
        case .learned: "Learned"
        case .pinned: "Always"
        }
    }

    func includes(_ origin: RuleOrigin) -> Bool {
        includes(Optional(origin))
    }

    /// P6-0g: nil = an app with settings but no rule (listed under All Rules only).
    func includes(_ origin: RuleOrigin?) -> Bool {
        switch self {
        case .all: true
        case .learned: origin == .learned
        case .pinned: origin == .pinned
        }
    }
}
