// P3-10: Headless tool for the owner's own P3-3 / P3-14 runs (001 §14.3.6). While a catalogued browser is
// frontmost it runs the real AX thread, observer and reader (`BrowserWatcher.live`) and prints one line per
// observation: the registrable domain (or "-"), the page state and the private flag. Nothing else: no URL, no
// host, no title, no field text. Ctrl-C stops it.
//
// Read-only: it listens to NSWorkspace activation notifications and reads the frontmost browser through AX. It
// never prompts for a permission (AXIsProcessTrusted only checks), never sets an AX attribute or performs an action,
// never activates or messages another app, and opens no window. The terminal running it needs Accessibility.
// Agents never run it against the owner's browsers (CLAUDE.md "Owner's machine is live").
//
//   watch-site [--psl PATH]   (default: Resources/PublicSuffixList/public_suffix_list.dat, run from the repo root)

import AppKit
import ApplicationServices

var pslPath = "Resources/PublicSuffixList/public_suffix_list.dat"
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--psl":
        guard let value = args.popFirst() else {
            FileHandle.standardError.write(Data("watch-site: --psl needs a path\n".utf8))
            exit(2)
        }
        pslPath = value
    case "-h", "--help":
        print("usage: watch-site [--psl PATH]   (Ctrl-C to stop). Prints domain, page state, private flag only.")
        exit(0)
    default:
        FileHandle.standardError.write(Data("watch-site: unknown argument \(arg) (see --help)\n".utf8))
        exit(2)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)

guard AXIsProcessTrusted() else {   // checks only; never shows the permission prompt
    FileHandle.standardError.write(Data("""
        watch-site: this terminal has no Accessibility permission, so browsers can't be read.
        Turn it on in System Settings → Privacy & Security → Accessibility for your terminal app, then run again.

        """.utf8))
    exit(1)
}

guard let text = try? String(contentsOfFile: pslPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("watch-site: can't read the Public Suffix List at \(pslPath)\n".utf8))
    exit(1)
}
let extractor = DomainExtractor(suffixList: PublicSuffixList(datContents: text))
let start = Date()

func stamp() -> String { String(format: "%7.2fs", Date().timeIntervalSince(start)) }

func describe(_ state: BrowserPageState) -> String {
    switch state {
    case .page: "page"
    case .notWebPage: "not-web"
    case .editingAddress: "editing-address"
    case .unknown: "unknown"
    }
}

/// Attaches the watcher to the frontmost app when it is a catalogued browser, detaches otherwise.
@MainActor final class Follower {
    let watcher = BrowserWatcher.live(extractor: extractor)
    let ownPid = ProcessInfo.processInfo.processIdentifier
    var attachedName: String?

    init() {
        watcher.onObservation = { [unowned self] _, _, o, _ in
            let domain = o.site?.siteKey ?? "-"
            let priv = o.isPrivate.map { $0 ? "private" : "normal" } ?? "private?"
            // P3-14: "bar" = read only from Zen/Firefox's address bar (applied, never learned: the P3-20 decision).
            let bar = o.readFromAddressBar ? "  bar" : ""
            print("\(stamp())  \(attachedName ?? "?")  \(domain)  \(describe(o.pageState))  \(priv)\(bar)")
        }
    }

    func follow(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ownPid, let bundleID = app.bundleIdentifier,
              let engine = BrowserCatalog.engine(for: bundleID, opensWebLinks: false) else {
            if attachedName != nil { print("\(stamp())  (no browser in front: detached)") }
            attachedName = nil
            watcher.detach()
            return
        }
        let known = BrowserCatalog.known[bundleID]
        let request = BrowserWatchRequest(engine: engine, alwaysPrivate: known?.alwaysPrivate ?? false,
                                          ignorePrivateWindows: false, appleScript: nil,
                                          privateSignal: known?.privateSignal ?? .none)   // QA P3-16: was always .none
        attachedName = "\(bundleID) [\(engine.rawValue)]"
        watcher.attach(pid: app.processIdentifier, bundleID: bundleID, request: request)
    }
}

MainActor.assumeIsolated {
    let follower = Follower()
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        MainActor.assumeIsolated { follower.follow(app) }
    }
    center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { follower.watcher.wake() }
    }
    follower.follow(NSWorkspace.shared.frontmostApplication)
    print("watching the frontmost browser (domain, page state, private flag). Switch apps; Ctrl-C to stop.")
    withExtendedLifetime(follower) { RunLoop.main.run() }
}
