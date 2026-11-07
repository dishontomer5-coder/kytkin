// P2-23: The Settings window (001 §2.2 UI): one AppKit NSWindow hosting the SwiftUI `SettingsView` through
// NSHostingController. design.md / R8: no SwiftUI `Settings` scene or `MenuBarExtra` (`SettingsLink` opens behind
// other windows in a menu-bar app).
//
// - One window, created on first use and reused: `show(tab:)` on an open window only switches the tab and brings
//   it to the front.
// - Bringing it forward in an LSUIElement (accessory) app: macOS 14 activation is cooperative, so `NSApp.activate()`
//   works when the user just clicked our menu (the system hands us activation) but may be refused otherwise.
//   `makeKeyAndOrderFront` + `orderFrontRegardless` make sure the window is at least on top in either case.
// - Closing it: an accessory app with no window would stay the active app (keys go nowhere), so when the last
//   titled window closes Kytkin hides itself and macOS activates the app you were in. That resign is what
//   AppController handles (P2-39 / P2-52 item 1).
// - Kytkin's own window is not a context (001 §12 W2): ContextMonitor ignores it; AppController hears about it
//   through the app's didBecomeActive / didResignActive notifications (AppEnvironment).

import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let selection = SettingsSelection()
    private let general: GeneralSettingsModel
    private let about: AboutInfo
    private var window: NSWindow?

    init(general: GeneralSettingsModel, about: AboutInfo) {
        self.general = general
        self.about = about
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Opens Settings on `tab`, or switches an open window to it, and brings it to the front.
    func show(tab: SettingsTab) {
        selection.tab = tab
        general.refresh()          // fresh login-item status and layout list (R8: don't cache the status)
        let window = self.window ?? makeWindow()
        if !window.isVisible { window.center() }
        NSApp.unhide(nil)          // closing hid the app; a hidden app's windows stay hidden even when ordered front
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(selection: selection, general: general, about: about))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Kytkin Settings"
        window.setContentSize(SettingsView.size)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)   // open on the Space you're on, not jump away
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        general.refresh()          // e.g. back from System Settings → Login Items
    }

    func windowWillClose(_ notification: Notification) {
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) }
        if others.isEmpty { NSApp.hide(nil) }
    }
}
