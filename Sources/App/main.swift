// P0-5: Entry point. A plain AppKit app with no storyboard; LSUIElement hides the Dock icon.

import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // NSApplication.delegate is weak; keep the delegate alive for the whole run loop.
    withExtendedLifetime(delegate) { app.run() }
}
