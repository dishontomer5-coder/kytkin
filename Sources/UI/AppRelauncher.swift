// P2-22 (P2-46, 001 §6.1 step 4): "Quit & Reopen". An Input Monitoring grant made while Kytkin runs usually takes
// effect only after a relaunch. Only ever called from a user click in the menu (or, later, the Permissions tab).
//
// The command (a shell that waits for this process to exit, then opens this same app bundle) is Core's
// `RelaunchCommand`: arguments only, never pasted into the script, and a bounded wait.

import AppKit

@MainActor enum AppRelauncher {
    static func quitAndReopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RelaunchCommand.shell)
        process.arguments = RelaunchCommand.arguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                      bundlePath: Bundle.main.bundlePath)
        do {
            try process.run()
        } catch {
            NSSound.beep()   // couldn't schedule the reopen: stay running rather than quit for nothing
            return
        }
        NSApp.terminate(nil)
    }
}
