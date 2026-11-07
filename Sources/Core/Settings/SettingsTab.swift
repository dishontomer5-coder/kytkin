// P2-23: The tabs of the Settings window (001 §5.2), in the order they appear. General and About are built in P2-23;
// the others show a one-line "coming soon" placeholder until their task lands (Languages P2-24, Rules/Apps/Convert
// P2-25, Permissions P2-26), so each later task only replaces its placeholder. Browsers & Sites is Phase 3.

import Foundation

enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general, languages, rules, convert, apps, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .languages: "Languages"
        case .rules: "Rules"
        case .convert: "Convert"
        case .apps: "Apps"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    /// SF Symbol name for the tab item.
    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .languages: "globe"
        case .rules: "list.bullet"
        case .convert: "arrow.left.arrow.right"
        case .apps: "square.grid.2x2"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }

    /// True while the tab is still a placeholder (the task that fills it isn't built yet).
    var isPlaceholder: Bool {
        switch self {
        case .general, .about: false
        case .languages, .rules, .convert, .apps, .permissions: true
        }
    }

    /// The one line a placeholder tab shows.
    var comingSoonText: String {
        switch self {
        case .languages: "Choosing your language pair and importing layouts is coming soon."
        case .rules: "A list of your rules is coming soon. For now, use Pin and Forget in the menu."
        case .convert: "Double-Shift settings are coming soon."
        case .apps: "Per-app settings are coming soon."
        case .permissions: "An overview of Kytkin's permissions is coming soon."
        case .general, .about: ""
        }
    }
}
