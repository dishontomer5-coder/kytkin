// P2-56: A main menu for an app with no menu bar. Kytkin is an accessory (LSUIElement) app, so macOS never shows
// this menu, but its key equivalents still work while one of Kytkin's windows is in front: ⌘W closes the window,
// ⌘Q quits, and the Edit shortcuts (⌘C, ⌘V, ⌘A, ⌘Z…) work in text fields such as the Rules filter. Esc closes a
// window through `KytkinWindow.cancelOperation`. Installed once at launch; nothing here runs on its own.

import AppKit

@MainActor enum MainMenu {
    static func install(appName: String) {
        let main = NSMenu()

        let app = NSMenu(title: appName)
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(window, to: main)

        NSApp.mainMenu = main
    }

    private static func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
