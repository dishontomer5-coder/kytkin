// P0-5: App lifecycle. Creates the menu-bar status item at launch.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    // P2-14: the one switcher for the app (P2-20's AppEnvironment will own it).
    private var inputSourceSwitcher: InputSourceSwitcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let switcher = InputSourceSwitcher.makeTIS()
        inputSourceSwitcher = switcher
        statusItemController = StatusItemController(switcher: switcher)
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.stop()
    }
}
