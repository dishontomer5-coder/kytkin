// P2-22: One line of the menu-bar menu as MenuModel decided it. StatusItemController renders each one as an
// NSMenuItem and maps `Action` to a call; it decides nothing.

import Foundation

struct MenuItemModel: Equatable {
    enum Kind: Equatable {
        /// A grayed line (context, warning text, version without About).
        case info
        case action(Action)
        case separator
        /// DEBUG builds: the "DEBUG: Switch to" submenu (the UI fills it from the installed sources).
        case debugSwitchSubmenu
    }

    enum Action: Equatable {
        case pinCurrent
        case forgetCurrent
        case togglePause
        case openSettings(SettingsTarget)
        case quitAndReopen
        case restartKeyboard
        /// Show the file in Finder (the kept original or the damaged settings file).
        case revealFile(URL)
        case quit
    }

    /// Where `openSettings` should land. The Settings window (P2-23) maps it to a tab; until it exists the
    /// hook is unset and MenuModel hides or disables these items.
    enum SettingsTarget: Equatable {
        case general, permissions, about
    }

    var kind: Kind
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    /// NSMenuItem.indentationLevel: sub-lines of a warning.
    var indent: Int
    /// Command-key equivalent ("," or "q"), empty for none.
    var keyEquivalent: String

    static func info(_ title: String, indent: Int = 0) -> MenuItemModel {
        MenuItemModel(kind: .info, title: title, isEnabled: false, isChecked: false, indent: indent, keyEquivalent: "")
    }

    static func action(_ title: String, _ action: Action, enabled: Bool = true, checked: Bool = false,
                       indent: Int = 0, key: String = "") -> MenuItemModel {
        MenuItemModel(kind: .action(action), title: title, isEnabled: enabled, isChecked: checked, indent: indent,
                      keyEquivalent: key)
    }

    static let separator = MenuItemModel(kind: .separator, title: "", isEnabled: false, isChecked: false, indent: 0,
                                         keyEquivalent: "")
}
