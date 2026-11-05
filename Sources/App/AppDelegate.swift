// P0-5: App lifecycle. Creates the menu-bar status item at launch.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.stop()
    }
}
