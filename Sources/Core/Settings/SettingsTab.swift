// P2-23: The tabs of the Settings window (001 §5.2), in the order they appear.
// P6-0c (owner 2026-11-17, visual review §2.2): 8 tabs became 6, ordered by how often a first-time user needs them:
//   General      setup status (permissions, conflicts) on top, Kytkin on/off, your two languages, learning, menu bar,
//                Open at Login, setup again (was General + Languages' pair + Permissions)
//   Rules        unchanged
//   Double-Shift was Convert
//   Websites     was Browsers & Sites
//   Advanced     app exceptions (was Apps), keyboard layouts (Languages' import/export), diagnostics (Permissions'
//                keyboard status and typing protection), the Settings folder (was in About)
//   About        unchanged, minus the Settings folder
// P6-0g (design v2): app exceptions moved into Rules; Advanced is one pane (Keyboard Layouts, Troubleshooting).
// P6-0k (owner 2026-11-18): Statistics, before About; its toolbar title is the total (the window controller sets it).
// The window draws them as toolbar tabs (icon over title, `NSTabViewController.tabStyle = .toolbar`).

import Foundation

enum SettingsTab: String, CaseIterable, Sendable, Identifiable {
    case general, rules, doubleShift, websites, advanced, statistics, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .rules: "Rules"
        case .doubleShift: "Double-Shift"
        case .websites: "Websites"
        case .advanced: "Advanced"
        case .statistics: "Statistics"
        case .about: "About"
        }
    }

    /// SF Symbol name for the toolbar item.
    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .rules: "list.bullet.rectangle"
        case .doubleShift: "shift"
        case .websites: "globe"
        case .advanced: "slider.horizontal.3"
        case .statistics: "arrow.left.arrow.right"
        case .about: "info.circle"
        }
    }

    /// P6-0c: where a menu item's "Open Settings…" lands. Permissions now live in General's setup section.
    init(target: MenuItemModel.SettingsTarget) {
        switch target {
        case .general, .permissions: self = .general
        case .doubleShift: self = .doubleShift
        case .about: self = .about
        }
    }
}

