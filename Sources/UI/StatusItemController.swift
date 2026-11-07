// P0-5: Owns the menu-bar status item. Shows the current input language ("EN"/"HE").
// P2-14: reads the current source through InputSourceSwitching instead of the old CurrentInputSource enum.
// P2-43 (001 §12 W3): sets no callbacks of its own any more. The composition root calls `refresh()` and
// `sourcesListDidChange()`; it depends only on the `InputSourceSwitching` and `MenuControlling` protocols.
// P2-22: the full menu (001 §5.1). Core's `MenuModel` decides every line, text and enabled state; this class only
// renders it and maps each action to a call. The label is set only when it changes (P2-52 item 4). App names
// are cached (`AppDisplayNames`). The Settings window (P2-23) plugs in through `openSettings`.

import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Opens the Settings window at a tab (P2-23 sets it in AppEnvironment). While nil, "Settings…" is disabled
    /// and the "Open Settings…" hints and About are hidden.
    var openSettings: (@MainActor (MenuItemModel.SettingsTarget) -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let switcher: any InputSourceSwitching
    private let menuControl: any MenuControlling
    private let menu = NSMenu()
    private let appNames = AppDisplayNames(lookup: StatusItemController.lookUpAppName)
    private var shownLabel: MenuModel.Label?
    #if DEBUG
    private let debugSwitchMenu = NSMenu()
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
    func refresh() {
        let label = MenuModel.label(languageCode: switcher.currentInfo?.languageCode, state: menuControl.menuState)
        guard label != shownLabel, let button = statusItem.button else { return }
        shownLabel = label
        button.title = label.title
        button.appearsDisabled = label.dimmed
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
        let models = MenuModel.items(
            state: menuControl.menuState, currentSource: switcher.currentInfo, version: Self.version,
            settingsAvailable: openSettings != nil, includeDebug: Self.includeDebug,
            sourceName: { id in sources.first { $0.id == id }?.name ?? id.rawValue },
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
            return item
        case .action(let action):
            let item = NSMenuItem(title: model.title, action: #selector(performMenuAction(_:)), keyEquivalent: model.keyEquivalent)
            item.target = self
            item.representedObject = ActionBox(action)
            item.isEnabled = model.isEnabled
            item.state = model.isChecked ? .on : .off
            item.indentationLevel = model.indent
            return item
        case .debugSwitchSubmenu:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            #if DEBUG
            item.submenu = debugSwitchMenu
            rebuildDebugSwitchMenu()
            #endif
            return item
        }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = (sender.representedObject as? ActionBox)?.action else { return }
        switch action {
        case .pinCurrent: menuControl.pinCurrent()
        case .forgetCurrent: menuControl.forgetCurrent()
        case .togglePause: menuControl.setPaused(!menuControl.menuState.paused)
        case .openSettings(let target): openSettings?(target)
        case .quitAndReopen: AppRelauncher.quitAndReopen()
        case .restartKeyboard: menuControl.restartKeyboard()
        case .revealFile(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .quit: NSApp.terminate(nil)
        }
        refresh()
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The live lookup behind `AppDisplayNames` (cached there).
    private static func lookUpAppName(_ bundleID: String) -> String? {
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
