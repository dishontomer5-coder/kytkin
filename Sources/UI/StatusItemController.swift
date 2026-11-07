// P0-5: Owns the menu-bar status item. Shows the current input language ("EN"/"HE").
// P2-14: reads the current source through InputSourceSwitching instead of the old CurrentInputSource enum.
// P2-43 (001 §12 W3): sets no callbacks of its own any more. The composition root calls `refresh()` and
// `sourcesListDidChange()`; it depends only on the `InputSourceSwitching` and `MenuControlling` protocols.
// P2-20: a minimal menu for per-app memory (context line, Pin, Forget, Pause) plus DEBUG status lines for
// checklist §P2-17. The full menu with warnings is P2-22; it rebuilds on `menuNeedsUpdate` (P2-48 hook).

import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let switcher: any InputSourceSwitching
    private let menuControl: any MenuControlling
    private let menu = NSMenu()
    #if DEBUG
    private let debugSwitchMenu = NSMenu()
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

    /// Label refresh (any input-source change, Pause, context). Cheap.
    func refresh() {
        let language = switcher.currentInfo?.languageCode ?? ""
        var title = InputSourceLabel.label(forLanguages: [language])
        if menuControl.menuState.paused { title += "·" }   // 001 §5.1: a small dot while paused
        statusItem.button?.title = title
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
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menu.removeAllItems()
        let state = menuControl.menuState

        if let rule = state.currentRule {
            let appName = Self.appName(rule.context.bundleID)
            let line: String
            if let matched = rule.resolution.matched {
                line = "\(appName): \(sourceName(matched.inputSource)) (\(matched.origin.rawValue))"
            } else {
                line = "\(appName): no rule"
            }
            menu.addItem(disabled(line))
            let currentName = switcher.currentInfo?.name ?? switcher.current.rawValue
            menu.addItem(action("Always use \(currentName) in \(appName)", #selector(pin)))
            let forget = action("Forget rule for \(appName)", #selector(forget))
            forget.isEnabled = rule.resolution.matched != nil
            menu.addItem(forget)
        } else {
            menu.addItem(disabled("No app yet"))
        }
        let pause = action("Pause Kytkin", #selector(togglePause))
        pause.state = state.paused ? .on : .off
        menu.addItem(pause)
        if state.secureInputOn { menu.addItem(disabled("Typing protected by another app")) }

        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(disabled("Kytkin v\(version)"))

        #if DEBUG
        // P2-14 / P2-17 checklist tools. Debug builds only; counts and states, never keys.
        menu.addItem(.separator())
        menu.addItem(disabled("DEBUG: Keyboard: \(state.tapMode)\(state.degradedByWatchdog ? " (lowered)" : "")"))
        menu.addItem(disabled("DEBUG: Double-Shift count: \(state.doubleShiftCount)"))
        menu.addItem(disabled("DEBUG: Tap re-enables: \(state.tapReEnableCount)"))
        let debugItem = NSMenuItem(title: "DEBUG: Switch to", action: nil, keyEquivalent: "")
        debugItem.submenu = debugSwitchMenu
        menu.addItem(debugItem)
        rebuildDebugSwitchMenu()
        #endif

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Kytkin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func sourceName(_ id: InputSourceID) -> String {
        switcher.sources(includeDisabled: true).first { $0.id == id }?.name ?? id.rawValue
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    @objc private func pin() { menuControl.pinCurrent() }
    @objc private func forget() { menuControl.forgetCurrent() }
    @objc private func togglePause() { menuControl.setPaused(!menuControl.menuState.paused) }

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
