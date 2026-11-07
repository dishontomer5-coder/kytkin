// P2-25: How Settings → Rules sorts its list. Ties fall back to the name, then the rule id, so the order is stable.

import Foundation

enum RuleSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// A to Z.
    case name
    /// By language name, A to Z.
    case language
    /// Pinned first.
    case origin
    /// Newest first (the default).
    case lastUpdated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Name"
        case .language: "Language"
        case .origin: "Pinned first"
        case .lastUpdated: "Last updated"
        }
    }

    func sorted(_ rows: [RuleRow]) -> [RuleRow] {
        rows.sorted { a, b in
            switch self {
            case .name: break
            case .language:
                let c = a.languageName.localizedStandardCompare(b.languageName)
                if c != .orderedSame { return c == .orderedAscending }
            case .origin:
                if a.origin != b.origin { return a.isPinned }
            case .lastUpdated:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            }
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
