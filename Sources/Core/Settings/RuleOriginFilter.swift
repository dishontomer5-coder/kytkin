// P2-25: Settings → Rules "Show": all rules, only learned ones, or only pinned ones.

import Foundation

enum RuleOriginFilter: String, CaseIterable, Identifiable, Sendable {
    case all, learned, pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .learned: "Learned"
        case .pinned: "Pinned"
        }
    }

    func includes(_ origin: RuleOrigin) -> Bool {
        switch self {
        case .all: true
        case .learned: origin == .learned
        case .pinned: origin == .pinned
        }
    }
}
