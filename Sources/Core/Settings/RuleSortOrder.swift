// P2-25: How Settings → Rules sorts its list. Ties fall back to the name, then the rule id, so the order is stable.
// P6-0g (design v2, P1): no "Sort by" pop-up any more: a click on a column header picks the order, a second click
// reverses it (`reversed`). Each order's natural direction: names A to Z, Always first, newest first.

import Foundation

enum RuleSortOrder: String, CaseIterable, Identifiable, Sendable {
    /// A to Z.
    case name
    /// By language name, A to Z.
    case language
    /// Always first (P6-0g: then Learned, then apps without a rule).
    case origin
    /// Newest first (the default).
    case lastUpdated

    var id: String { rawValue }

    /// The column header.
    var title: String {
        switch self {
        case .name: "App or Website"
        case .language: "Language"
        case .origin: "Status"
        case .lastUpdated: "Last Updated"
        }
    }

    func sorted(_ rows: [RuleRow], reversed: Bool = false) -> [RuleRow] {
        func rank(_ row: RuleRow) -> Int {
            switch row.effectiveOrigin {
            case .pinned: 0
            case .learned: 1
            case nil: 2
            }
        }
        return rows.sorted { a, b in
            switch self {
            case .name: break
            case .language:
                let c = a.languageName.localizedStandardCompare(b.languageName)
                if c != .orderedSame { return (c == .orderedAscending) != reversed }
            case .origin:
                if rank(a) != rank(b) { return (rank(a) < rank(b)) != reversed }
            case .lastUpdated:
                if a.updatedAt != b.updatedAt { return (a.updatedAt > b.updatedAt) != reversed }
            }
            let c = a.name.localizedStandardCompare(b.name)
            if c != .orderedSame { return (c == .orderedAscending) != (reversed && self == .name) }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
