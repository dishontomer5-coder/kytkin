// P2-14 QA: Receives one distributed notification with `.deliverImmediately` and calls a main-actor handler.
// The block-based `addObserver(forName:object:queue:using:)` always uses `.coalesce`, and AppKit suspends
// distributed delivery while the app isn't active (NSDistributedNotificationCenter.h, `suspended`). A
// menu-bar app is almost never active, so a coalesced TIS notification could arrive late (after the 500 ms
// token window) and our own switch would be reported as external. `.deliverImmediately` is only available
// through the selector-based API, hence this small NSObject.

import Foundation

final class DistributedNotificationRelay: NSObject {
    private let handler: @MainActor () -> Void

    init(name: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: Notification.Name(name), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// The center doesn't retain its observers, so the relay unregisters itself when its owner drops it.
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ notification: Notification) {
        // Distributed notifications are delivered on the main thread; hop there anyway if that ever changes.
        let handler = self.handler   // a Sendable closure: nothing else of the relay crosses into the main actor
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler() }
        } else {
            DispatchQueue.main.async { [handler] in handler() }
        }
    }
}
