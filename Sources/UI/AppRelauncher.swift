// P2-22 (P2-46, 001 §6.1 step 4): "Quit & Reopen". An Input Monitoring grant made while Kytkin runs usually takes
// effect only after a relaunch. Only ever called from a user click in the menu (or, later, the Permissions tab).
//
// A tiny shell waits until this process has exited, then opens this same app bundle again. The pid and the
// bundle path are passed as arguments ($1, $2), never pasted into the script, so a path with quotes or spaces
// can't change what runs.

import AppKit

@MainActor enum AppRelauncher {
    static func quitAndReopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "kytkin-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        do {
            try process.run()
        } catch {
            NSSound.beep()   // couldn't schedule the reopen: stay running rather than quit for nothing
            return
        }
        NSApp.terminate(nil)
    }
}
