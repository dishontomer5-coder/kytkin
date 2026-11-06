// P2-15: Headless tool that prints each Context the tier-0 ContextMonitor emits, so the owner can check it
// before the menu is wired (P2-20/P2-22). Build and run it with `scripts/watch-context`; stop with Ctrl-C.
// It only listens to NSWorkspace notifications: no window, no Dock icon, no permission, and it never
// activates, hides or messages another app. It prints bundle IDs and generations only (001 §7 B7).
//
//   watch-context [--debounce-ms N]   (default 120)

import AppKit

var debounceMs: UInt64 = 120
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--debounce-ms":
        guard let value = args.popFirst().flatMap(UInt64.init) else {
            FileHandle.standardError.write(Data("watch-context: --debounce-ms needs a number\n".utf8))
            exit(2)
        }
        debounceMs = value
    case "-h", "--help":
        print("usage: watch-context [--debounce-ms N]   (Ctrl-C to stop)")
        exit(0)
    default:
        FileHandle.standardError.write(Data("watch-context: unknown argument \(arg) (see --help)\n".utf8))
        exit(2)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let start = Date()

MainActor.assumeIsolated {
    // ownBundleID: a command-line tool has none, so pass the Debug app's ID to show it being ignored.
    let monitor = ContextMonitor(source: WorkspaceAppActivationSource(),
                                 ownBundleID: "io.github.kytkin.Kytkin.dev",
                                 debounceNanos: debounceMs * 1_000_000)
    monitor.onChange = { context in
        let t = String(format: "%7.2fs", Date().timeIntervalSince(start))
        print("\(t)  gen \(context.generation)  \(context.bundleID)  (pid \(context.pid))")
    }
    monitor.start()
    print("watching app changes (debounce \(debounceMs) ms). Switch apps; press Ctrl-C to stop.")
    withExtendedLifetime(monitor) { RunLoop.main.run() }
}
