// P2-15: Tier-0 `AppActivationSource` over NSWorkspace (001 §2.2, research context-monitoring.md §1).
// No permission, no TCC entry. Observes, on the *workspace* notification center (NotificationCenter.default
// gets nothing):
//   - didActivateApplication → onActivate(bundleID, pid)
//   - didTerminateApplication → onTerminate(pid)
//   - activeSpaceDidChange → re-read the frontmost app (the activation isn't always sent on a Space change)
// and reports the frontmost app on `start()` (there is no initial notification).
// Thin by design: Kytkin's own activations, empty bundle IDs and duplicates are filtered by ContextAssembler.
// It only reads; it never activates, hides or messages another app.

import AppKit

@MainActor final class WorkspaceAppActivationSource: AppActivationSource {
    var onActivate: (@MainActor (String, Int32) -> Void)?
    var onTerminate: (@MainActor (Int32) -> Void)?

    private let center: NotificationCenter
    private let frontmost: @MainActor () -> NSRunningApplication?
    private var tokens: [NSObjectProtocol] = []

    /// Tests inject a private `NotificationCenter` and a fake `frontmost`; the app uses the defaults.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         frontmost: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.center = center
        self.frontmost = frontmost
    }

    func start() {
        guard tokens.isEmpty else { return }
        tokens = [
            observe(NSWorkspace.didActivateApplicationNotification) { source, app in
                if let app { source.report(app) }
            },
            observe(NSWorkspace.didTerminateApplicationNotification) { source, app in
                if let app { source.onTerminate?(app.pid) }
            },
            observe(NSWorkspace.activeSpaceDidChangeNotification) { source, _ in
                source.reportFrontmost()
            },
        ]
        reportFrontmost()
    }

    func stop() {
        tokens.forEach(center.removeObserver)
        tokens = []
    }

    // MARK: - Private

    /// The Sendable parts of the notification's NSRunningApplication.
    private struct AppInfo: Sendable {
        let bundleID: String
        let pid: Int32
    }

    private func report(_ app: AppInfo) {
        onActivate?(app.bundleID, app.pid)
    }

    private func reportFrontmost() {
        guard let app = frontmost() else { return }
        report(AppInfo(bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier))
    }

    private func observe(_ name: Notification.Name,
                         _ handle: @escaping @MainActor (WorkspaceAppActivationSource, AppInfo?) -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // Read the Sendable values here, then hop: NSWorkspace posts these on the main thread.
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let info = running.map { AppInfo(bundleID: $0.bundleIdentifier ?? "", pid: $0.processIdentifier) }
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self, info)
            }
        }
    }
}
