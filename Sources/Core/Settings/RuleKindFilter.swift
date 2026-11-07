// P3-15 (001 §14.8, D7): Settings → Rules "Kind": all rules, only app rules, or only website rules (whole-site and
// single-address rules together). Browsers & Sites has no second list; its "Show in Rules" opens Rules on `.websites`.
// Chat rules (Phase 4) show under "All" only.

import Foundation

enum RuleKindFilter: String, CaseIterable, Identifiable, Sendable {
    case all, apps, websites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        case .websites: "Websites"
        }
    }

    func includes(_ scope: RuleScope) -> Bool {
        switch (self, scope) {
        case (.all, _): true
        case (.apps, .app): true
        case (.websites, .site), (.websites, .siteHost): true
        default: false
        }
    }
}
