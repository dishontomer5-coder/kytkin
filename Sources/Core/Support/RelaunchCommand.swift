// P2-22 QA: the command behind "Quit & Reopen" (AppRelauncher, UI), pure so it can be unit-tested headlessly.
// A tiny shell waits until Kytkin's process has exited, then opens the app bundle again. The pid and the bundle
// path are passed as arguments ($1, $2), never pasted into the script, so a path with quotes or spaces
// ("Kytkin Dev.app") can't change what runs. The wait is bounded (300 × 0.2 s ≈ 60 s): if Kytkin hasn't exited by
// then it is stuck or the quit was cancelled, so the shell gives up without opening anything, rather than lingering
// and reopening Kytkin at some later, unrelated quit.

import Foundation

enum RelaunchCommand {
    static let shell = "/bin/sh"

    /// `opener` and `maxPolls` are parameters only so tests can run the script with a harmless opener.
    static func arguments(pid: Int32, bundlePath: String, opener: String = "/usr/bin/open",
                          maxPolls: Int = 300) -> [String] {
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do "
            + "[ \"$i\" -ge \(maxPolls) ] && exit 1; i=$((i+1)); /bin/sleep 0.2; done; \"$3\" \"$2\""
        return ["-c", script, "kytkin-relaunch", String(pid), bundlePath, opener]
    }
}
