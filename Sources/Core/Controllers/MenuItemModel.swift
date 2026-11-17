// P2-22: One line of the menu-bar menu as MenuModel decided it. StatusItemController renders each one as an
// NSMenuItem and maps `Action` to a call; it decides nothing.
// P6-0c (visual review N1–N5, flows S2/S3): a section header kind, a ⚠ symbol and a subtitle (macOS 14.4+ shows it
// under the title; older systems get it as the tooltip), so a warning is one clickable line.
// P6-0g (design v2): the "Always use" line with the Kytkin key (`languageKey`): two halves, the filled one is the
// language this app or website is pinned to.

import Foundation

struct MenuItemModel: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A grayed line (context, warning text, version without About).
        case info
        /// P6-0c: a section header (`NSMenuItem.sectionHeader` on macOS 14): the app or website the block is about.
        case header
        case action(Action)
        case separator
        /// P6-0g: "Always use" and the Kytkin key (a custom view: one click on a half pins it, on the filled half
        /// unpins).
        case languageKey(LanguageKey)
        /// DEBUG builds: the "Switch to" submenu (the UI fills it from the installed sources).
        case debugSwitchSubmenu
        /// P6-0f: a submenu of these lines (DEBUG builds: "Debug ▸" holds every DEBUG line).
        indirect case submenu([MenuItemModel])
    }

    /// P6-0g: the menu's Kytkin key. `chosen` is the pair member the current scope is pinned to (nil: none pinned).
    struct LanguageKey: Equatable, Sendable {
        struct Half: Equatable, Sendable {
            /// "EN", "HE".
            let letters: String
            /// "English", "Hebrew".
            let name: String
            let source: InputSourceID
        }

        let a: Half
        let b: Half
        let chosen: PairSide?

        func half(_ side: PairSide) -> Half { side == .a ? a : b }

        /// What a click on `side` does: the filled half again unpins (back to following the last switch).
        func action(for side: PairSide) -> Action {
            chosen == side ? .unpinCurrent : .pinCurrentTo(half(side).source)
        }

        /// P6-0g QA: the keyboard fallback. A custom menu view can't take arrow keys, so Return on the highlighted
        /// "Always use" line pins a language too: with nothing pinned, the language selected now (`current`, else the
        /// first); with a pin, the other half. "Follow My Last Switch" (a plain item) unpins.
        func keyboardAction(current: InputSourceID?) -> Action {
            switch chosen {
            case .a: return .pinCurrentTo(b.source)
            case .b: return .pinCurrentTo(a.source)
            case nil: return .pinCurrentTo(current == b.source ? b.source : a.source)
            }
        }
    }

    enum Action: Equatable {
        case pinCurrent
        /// P6-0g: "Always use" a pair member (a half of the Kytkin key).
        case pinCurrentTo(InputSourceID)
        /// P6-0c (visual review N5): choosing the checked "Always Use …" again unpins it. P6-0g: "Follow My Last
        /// Switch", and the filled half clicked again.
        case unpinCurrent
        case forgetCurrent
        /// P6-0c (flows S3, owner: double-Shift only): "Turn Off Double-Shift in {App}" on/off.
        case toggleConvertInCurrentApp
        case togglePause
        /// P6-0c (visual review N2): "Turn Kytkin On" when it is turned off.
        case turnOn
        case openSettings(SettingsTarget)
        case quitAndReopen
        case restartKeyboard
        /// Show the file in Finder (the kept original or the damaged settings file).
        case revealFile(URL)
        /// P6-3: the release page, in the browser (a click; Kytkin never downloads anything).
        case openURL(URL)
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
    /// NSMenuItem.indentationLevel. P6-0g (review P3): one left inset for every item, so 0 everywhere today.
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

    /// P6-0g: "Always use" with the Kytkin key.
    static func languageKey(_ title: String, _ key: LanguageKey, enabled: Bool = true) -> MenuItemModel {
        MenuItemModel(kind: .languageKey(key), title: title, isEnabled: enabled, isChecked: false, indent: 0,
                      keyEquivalent: "")
    }

    static let separator = MenuItemModel(kind: .separator, title: "", isEnabled: false, isChecked: false, indent: 0,
                                         keyEquivalent: "")

    /// P6-0c: the warning symbol (a template image; the menu bar and menus stay colourless).
    static let warningSymbol = "exclamationmark.triangle"
}
