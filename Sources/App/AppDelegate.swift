// P0-5: App lifecycle. P2-20: builds the composition root (AppEnvironment) at launch and stops it on quit.
// P2-23: a reopen (Finder double-click while running) opens Settings.
// P2-56: installs the hidden main menu (⌘W closes Kytkin's windows, Edit shortcuts work in text fields).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(appName: AppEnvironment.appName)
        let env = AppEnvironment()
        environment = env
        env.start()
    }

    /// P2-23: opening Kytkin again while it runs (double-click in Finder, `open`) shows Settings: the usual way to
    /// reach a menu-bar app's window besides its menu.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        environment?.openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flushes held keys, removes the tap and saves pending preferences.
        environment?.stop()
    }
}
