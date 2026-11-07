// P2-23: The Settings window (001 §2.2 UI): one AppKit NSWindow hosting the SwiftUI `SettingsView` through
// NSHostingController. design.md / R8: no SwiftUI `Settings` scene or `MenuBarExtra` (`SettingsLink` opens behind
// other windows in a menu-bar app).
//
// - One window, created on first use and reused: `show(tab:)` on an open window only switches the tab and brings
//   it to the front.
// - Bringing it forward and closing it go through `WindowPresenter` (P2-56: unhide first, activate, fall back to
//   `activate(ignoringOtherApps:)` if the window didn't get the keyboard; hide Kytkin when its last window closes, so
//   macOS activates the app you were in). That resign is what AppController handles (P2-39 / P2-52 item 1).
//   ⌘W (hidden main menu) and Esc (`KytkinWindow`) close it.
// - P2-26: while the Permissions tab is showing in an open window, the permission poll runs every 1 s.
//   P3-12 (P2-63): and only while that window is on screen: not while Kytkin is hidden or other windows fully
//   cover it (the window's occlusion state; the poll resumes, with a fresh read, when it shows again).
// - Kytkin's own window is not a context (001 §12 W2): ContextMonitor ignores it; AppController hears about it
//   through the app's didBecomeActive / didResignActive notifications (AppEnvironment).

import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let selection = SettingsSelection()
    private let general: GeneralSettingsModel
    private let about: AboutInfo
    private let tabs: TabModels   // P2-24, P2-25
    private var window: NSWindow?

    /// P2-24 Languages (via the environment) and P2-25 Rules, Convert and Apps.
    struct TabModels {
        let languages: LanguagesSettingsModel
        let rules: RulesSettingsModel
        let convert: ConvertSettingsModel
        let apps: AppsSettingsModel
        let permissions: PermissionsSettingsModel   // P2-26
    }

    /// P2-26: General → "Show Welcome Again".
    private let showWelcome: @MainActor () -> Void

    init(general: GeneralSettingsModel, about: AboutInfo, tabs: TabModels,
         showWelcome: @escaping @MainActor () -> Void) {
        self.general = general
        self.about = about
        self.tabs = tabs
        self.showWelcome = showWelcome
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Opens Settings on `tab`, or switches an open window to it, and brings it to the front.
    func show(tab: SettingsTab) {
        selection.tab = tab
        general.refresh()          // fresh login-item status and layout list (R8: don't cache the status)
        refreshTabs()
        let window = self.window ?? makeWindow()
        WindowPresenter.show(window)   // P2-56
        tabs.permissions.setCovered(false)   // P3-12: just brought to the front; occlusion changes follow
        updatePermissionsPolling()
    }

    /// P2-26: a grant, the tap mode or Secure Input changed (the root's display fan-out). Silent.
    func permissionsChanged() {
        guard isOpen else { return }
        tabs.permissions.reload()
    }

    /// P2-26: the 1 s permission poll runs only while the Permissions tab shows in an open window.
    private func updatePermissionsPolling() {
        tabs.permissions.setVisible(isOpen && selection.tab == .permissions)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(selection: selection, general: general, about: about,
                                                                 rules: tabs.rules, convert: tabs.convert,
                                                                 apps: tabs.apps, permissions: tabs.permissions,
                                                                 showWelcome: showWelcome,
                                                                 tabChanged: { [weak self] in
                                                                     self?.updatePermissionsPolling()
                                                                 })
            .environment(tabs.languages))   // P2-24: the Languages model goes through the environment
        hosting.sizingOptions = []
        let window = KytkinWindow(contentViewController: hosting)   // P2-56: Esc closes it
        // QA (P2-23): no minimize. A minimized window leaves the accessory app active with no window (keys go
        // nowhere) and skips windowWillClose, so Kytkin never hides; Settings windows don't minimize anyway.
        window.styleMask = [.titled, .closable]
        window.title = "Kytkin Settings"
        window.setContentSize(SettingsView.size)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)   // open on the Space you're on, not jump away
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    /// P3-12: hidden (Kytkin hidden, another Space) or fully covered → the 1 s poll pauses; back on screen → resumes.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        tabs.permissions.setCovered(!window.occlusionState.contains(.visible))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        general.refresh()          // e.g. back from System Settings → Login Items
        refreshTabs()
    }

    /// P2-24/P2-25: layouts, layout names for Rules, and the running apps Apps can add (read only when Settings
    /// opens or comes to the front, e.g. back from System Settings → Keyboard → Input Sources).
    private func refreshTabs() {
        tabs.languages.refresh()
        tabs.rules.refresh()
        tabs.apps.refresh()
        tabs.permissions.reload()
    }

    func windowWillClose(_ notification: Notification) {
        tabs.permissions.setVisible(false)
        if let window { WindowPresenter.willClose(window) }
    }
}
