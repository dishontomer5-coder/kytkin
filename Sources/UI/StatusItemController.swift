// P0-5: Owns the menu-bar status item. Shows the current input language ("EN"/"HE").
// P2-14: reads the current source through InputSourceSwitching instead of the old CurrentInputSource enum.
// P2-43 (001 §12 W3): sets no callbacks of its own any more. The composition root calls `refresh()` and
// `sourcesListDidChange()`; it depends only on the `InputSourceSwitching` and `MenuControlling` protocols.
// P2-22: the full menu (001 §5.1). Core's `MenuModel` decides every line, text and enabled state; this class only
// renders it and maps each action to a call. The label is set only when it changes (P2-52 item 4). App names
// are cached (`AppDisplayNames`). The Settings window (P2-23) plugs in through `openSettings`.
// P6-0c (owner 2026-11-17, visual review §3): Kytkin's template glyph + the language letters (Settings → General can
// show the icon only or the letters only), at a fixed width so neighbours never move when the language changes; a
// distinct glyph for paused, needs attention and off (no more "·"); a VoiceOver label. No colour, no animation.

import AppKit
import QuartzCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Opens the Settings window at a tab (P2-23 sets it in AppEnvironment). While nil, "Settings…" is disabled
    /// and the "Open Settings…" hints are hidden.
    var openSettings: (@MainActor (MenuItemModel.SettingsTarget) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let switcher: any InputSourceSwitching
    private let menuControl: any MenuControlling
    private let menu = NSMenu()
    private let appNames = AppDisplayNames(lookup: StatusItemController.lookUpAppName)
    private var shownLabel: MenuModel.Label?
    #if DEBUG
    private var debugSwitchMenu = NSMenu()
    private static let includeDebug = true
    #else
    private static let includeDebug = false
    #endif

    init(switcher: any InputSourceSwitching, menu menuControl: any MenuControlling) {
        self.switcher = switcher
        self.menuControl = menuControl
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refresh()
    }

    /// Label refresh (any input-source change, Pause, context, warnings). Touches the button only on a change.
    /// P6-0e: the whole item is one template image (`MenuBarGlyph.itemImage`: the logo with the on language's half
    /// filled, 5 pt (P6-0g), the letters in a fixed 20 pt frame), so its width never moves. A language change cross-fades
    /// over 150 ms (Colors.md), never with Reduce Motion.
    func refresh() {
        let state = menuControl.menuState
        let info = switcher.currentInfo
        let label = MenuModel.label(languageCode: info?.languageCode, languageName: info.map(LanguageNames.friendly), state: state,
                                    display: state.menuBarDisplay, current: info?.id)
        guard label != shownLabel, let button = statusItem.button else { return }
        let languageChanged = shownLabel.map { $0.look == label.look && ($0.side != label.side || $0.letters != label.letters) }
            ?? false
        shownLabel = label
        if languageChanged, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            button.layer?.add(fade, forKey: "kytkin.language")
        }
        let image = MenuBarGlyph.itemImage(for: label)
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.appearsDisabled = false   // the artwork draws paused (45 %) and off (35 %) itself
        button.setAccessibilityLabel(label.accessibilityLabel)
        button.setAccessibilityHelp("Click for Kytkin options")
        statusItem.length = ceil(CGFloat(MenuModel.ItemLayout.width(for: label.display)) + 8)   // P6-0e QA: per mode
    }

    func sourcesListDidChange() {
        refresh()
        #if DEBUG
        rebuildDebugSwitchMenu()
        #endif
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menuControl.menuWillOpen()   // P2-48: conflicts.refresh() + permissions.refresh()
        rebuildMenu()
        refresh()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        let sources = switcher.sources(includeDisabled: true)
        // P6-0g (review P1): the Debug submenu only in Debug builds, and only when the menu is opened with Option-click.
        let optionClick = NSEvent.modifierFlags.contains(.option)
        let models = MenuModel.items(
            state: menuControl.menuState, currentSource: switcher.currentInfo,
            settingsAvailable: openSettings != nil, includeDebug: Self.includeDebug && optionClick,
            sourceName: { id in sources.first { $0.id == id }.map(LanguageNames.friendly) ?? id.rawValue },   // P6-0g
            sourceCode: { id in
                let code = InputSourceLabel.label(forLanguages: [sources.first { $0.id == id }?.languageCode ?? ""])
                return code == InputSourceLabel.unknown ? nil : code
            },
            appName: { [appNames] in appNames.name(for: $0) })
        for model in models { menu.addItem(render(model)) }
    }

    private func render(_ model: MenuItemModel) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return .separator()
        case .info:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = model.indent
            decorate(item, model)
            return item
        case .header:
            // P6-0c (visual review N3): the app or website the block is about.
            if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: model.title) }
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .action(let action):
            let item = NSMenuItem(title: model.title, action: #selector(performMenuAction(_:)), keyEquivalent: model.keyEquivalent)
            item.target = self
            item.representedObject = ActionBox(action)
            item.isEnabled = model.isEnabled
            item.state = model.isChecked ? .on : .off
            item.indentationLevel = model.indent
            decorate(item, model)
            return item
        case .languageKey(let key):
            // P6-0g (lg-menu): "Always use" with the Kytkin key, a custom view.
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            item.view = KytkinKeyMenuView(title: model.title, key: key, enabled: model.isEnabled) { [weak self] side in
                self?.perform(key.action(for: side))
            }
            return item
        case .submenu(let lines):
            // P6-0f: "Debug ▸" (DEBUG builds only).
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: model.title)
            sub.autoenablesItems = false
            for line in lines { sub.addItem(render(line)) }
            item.submenu = sub
            return item
        case .debugSwitchSubmenu:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            #if DEBUG
            // P6-0f: a fresh menu each rebuild (the old one may still sit under the previous "Debug ▸" item, and a
            // menu can have only one supermenu).
            debugSwitchMenu = NSMenu()
            item.submenu = debugSwitchMenu
            rebuildDebugSwitchMenu()
            #endif
            return item
        }
    }

    /// P6-0c (visual review N1): the ⚠ template symbol and the fix as a subtitle (macOS 14.4+) or tooltip.
    private func decorate(_ item: NSMenuItem, _ model: MenuItemModel) {
        if let symbol = model.symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Warning")
            image?.isTemplate = true
            item.image = image
        }
        if let subtitle = model.subtitle {
            if #available(macOS 14.4, *) { item.subtitle = subtitle } else { item.toolTip = subtitle }
        }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        perform(action)
    }

    private func perform(_ action: MenuItemModel.Action) {
        switch action {
        case .pinCurrent: menuControl.pinCurrent()
        case .pinCurrentTo(let source): menuControl.pinCurrent(to: source)
        case .unpinCurrent: menuControl.unpinCurrent()
        case .forgetCurrent: menuControl.forgetCurrent()
        case .toggleConvertInCurrentApp:
            menuControl.setConvertInCurrentApp(menuControl.menuState.convertOffInCurrentApp)
        case .turnOn: menuControl.turnOn()
        case .togglePause: menuControl.setPaused(!menuControl.menuState.paused)
        case .openSettings(let target): openSettings?(target)
        case .quitAndReopen: AppRelauncher.quitAndReopen()
        case .restartKeyboard: menuControl.restartKeyboard()
        case .revealFile(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openURL(let url): NSWorkspace.shared.open(url)   // P6-3: the release page, on the user’s click
        case .quit: NSApp.terminate(nil)
        }
        refresh()
    }

    /// The live lookup behind `AppDisplayNames` (cached there).
    static func lookUpAppName(_ bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    #if DEBUG
    private func rebuildDebugSwitchMenu() {
        debugSwitchMenu.removeAllItems()
        debugSwitchMenu.autoenablesItems = false
        for source in switcher.sources(includeDisabled: false) {
            let item = NSMenuItem(title: "\(source.name) (\(source.id.rawValue))",
                                  action: #selector(debugSelect(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.id.rawValue
            debugSwitchMenu.addItem(item)
        }
    }

    @objc private func debugSelect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if !menuControl.selectFromMenu(InputSourceID(raw)) { NSSound.beep() }
    }
    #endif
}

/// Carries a Core menu action through `NSMenuItem.representedObject`.
private final class ActionBox: NSObject {
    let action: MenuItemModel.Action
    init(_ action: MenuItemModel.Action) { self.action = action }
}
