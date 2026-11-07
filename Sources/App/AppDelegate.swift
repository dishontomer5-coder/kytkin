// P0-5: App lifecycle. P2-20: builds the composition root (AppEnvironment) at launch and stops it on quit.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment()
        environment = env
        env.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flushes held keys, removes the tap and saves pending preferences.
        environment?.stop()
    }
}
