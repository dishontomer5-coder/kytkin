// P0-5: Owns the menu-bar status item. Shows the current input language ("EN"/"HE").
// P2-14: reads the current source through InputSourceSwitching instead of the old CurrentInputSource enum.

import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let switcher: InputSourceSwitcher
    #if DEBUG
    private let debugSwitchMenu = NSMenu()
    #endif

    init(switcher: InputSourceSwitcher) {
        self.switcher = switcher
        super.init()
        statusItem.menu = makeMenu()
        refreshTitle()
        // P2-14: only real changes arrive here (duplicates are dropped by SwitchAttributor).
        // P2-20 note: the composition root will own onChange and must keep calling refreshTitle.
        switcher.onChange = { [weak self] _ in self?.refreshTitle() }
        switcher.onSourcesListChanged = { [weak self] in
            self?.refreshTitle()
            #if DEBUG
            self?.rebuildDebugSwitchMenu()
            #endif
        }
    }

    func stop() {
        switcher.onChange = nil
        switcher.onSourcesListChanged = nil
    }

    private func refreshTitle() {
        let language = switcher.currentInfo?.languageCode ?? ""
        statusItem.button?.title = InputSourceLabel.label(forLanguages: [language])
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let about = NSMenuItem(title: "Kytkin v\(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)

        #if DEBUG
        // P2-14: manual check of `select` (001 §10 P2-14). Debug builds only; the real menu is P2-22.
        menu.addItem(.separator())
        let debugItem = NSMenuItem(title: "DEBUG: Switch to", action: nil, keyEquivalent: "")
        debugItem.submenu = debugSwitchMenu
        menu.addItem(debugItem)
        rebuildDebugSwitchMenu()
        #endif

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kytkin",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q") // ⌘Q
        quit.target = NSApp
        menu.addItem(quit)
        return menu
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
        if !switcher.select(InputSourceID(raw), reason: .menu) { NSSound.beep() }
    }
    #endif
}
