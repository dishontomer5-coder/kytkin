// P2-22: One line of the menu-bar menu as MenuModel decided it. StatusItemController renders each one as an
// NSMenuItem and maps `Action` to a call; it decides nothing.
// P6-0c (visual review N1–N5, flows S2/S3): a section header kind, a ⚠ symbol and a subtitle (macOS 14.4+ shows it
// under the title; older systems get it as the tooltip), so a warning is one clickable line.

import Foundation

struct MenuItemModel: Equatable {
    enum Kind: Equatable {
        /// A grayed line (context, warning text, version without About).
        case info
        /// P6-0c: a section header (`NSMenuItem.sectionHeader` on macOS 14): the app or website the block is about.
        case header
        case action(Action)
        case separator
        /// DEBUG builds: the "DEBUG: Switch to" submenu (the UI fills it from the installed sources).
        case debugSwitchSubmenu
    }

    enum Action: Equatable {
        case pinCurrent
        /// P6-0c (visual review N5): choosing the checked "Always Use …" again unpins it.
        case unpinCurrent
        case forgetCurrent
        /// P6-0c (flows S3, owner: double-Shift only): "Don't Convert in {App}" on/off.
        case toggleConvertInCurrentApp
        case togglePause
        /// P6-0c (visual review N2): "Turn Kytkin On" when it is turned off.
        case turnOn
        case openSettings(SettingsTarget)
        case quitAndReopen
        case restartKeyboard
        /// Show the file in Finder (the kept original or the damaged settings file).
        case revealFile(URL)
        case quit
    }

    /// Where `openSettings` should land. The Settings window (P2-23) maps it to a tab; until it exists the
    /// hook is unset and MenuModel hides or disables these items.
    /// P6-0c: `.permissions` lands on General's setup section (the Permissions tab is gone).
    enum SettingsTarget: Equatable {
        case general, permissions, doubleShift, about
    }

    var kind: Kind
    var title: String
    var isEnabled: Bool
    var isChecked: Bool
    /// NSMenuItem.indentationLevel: sub-lines of a warning.
    var indent: Int
    /// Command-key equivalent ("," or "q"), empty for none.
    var keyEquivalent: String
    /// P6-0c: an SF Symbol drawn as a template image before the title (warnings only: "exclamationmark.triangle").
    var symbol: String? = nil
    /// P6-0c: a second, smaller line (macOS 14.4+), else the tooltip.
    var subtitle: String? = nil

    static func info(_ title: String, indent: Int = 0, symbol: String? = nil) -> MenuItemModel {
        MenuItemModel(kind: .info, title: title, isEnabled: false, isChecked: false, indent: indent, keyEquivalent: "",
                      symbol: symbol)
    }

    static func header(_ title: String) -> MenuItemModel {
        MenuItemModel(kind: .header, title: title, isEnabled: false, isChecked: false, indent: 0, keyEquivalent: "")
    }

    static func action(_ title: String, _ action: Action, enabled: Bool = true, checked: Bool = false,
                       indent: Int = 0, key: String = "", symbol: String? = nil,
                       subtitle: String? = nil) -> MenuItemModel {
        MenuItemModel(kind: .action(action), title: title, isEnabled: enabled, isChecked: checked, indent: indent,
                      keyEquivalent: key, symbol: symbol, subtitle: subtitle)
    }

    static let separator = MenuItemModel(kind: .separator, title: "", isEnabled: false, isChecked: false, indent: 0,
                                         keyEquivalent: "")

    /// P6-0c: the warning symbol (a template image; the menu bar and menus stay colourless).
    static let warningSymbol = "exclamationmark.triangle"
}
