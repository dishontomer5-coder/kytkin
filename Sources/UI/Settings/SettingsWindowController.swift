// P2-23: The Settings window (001 §2.2 UI): one AppKit NSWindow; P6-0c: an `NSTabViewController` with toolbar-style
// tabs (icon over title), each tab a SwiftUI `SettingsTabPane` in its own
// NSHostingController. design.md / R8: no SwiftUI `Settings` scene or `MenuBarExtra` (`SettingsLink` opens behind
// other windows in a menu-bar app).
//
// - One window, created on first use and reused: `show(tab:)` on an open window only switches the tab and brings
//   it to the front.
// - Bringing it forward and closing it go through `WindowPresenter` (P2-56: unhide first, activate, fall back to
//   `activate(ignoringOtherApps:)` if the window didn't get the keyboard; hide Kytkin when its last window closes, so
//   macOS activates the app you were in). That resign is what AppController handles (P2-39 / P2-52 item 1).
//   ⌘W (hidden main menu) and Esc (`KytkinWindow`) close it.
// - P2-26: while the permission rows show (P6-0c: General or Advanced) in an open window, the poll runs every 1 s.
//   P3-12 (P2-63): and only while that window is on screen: not while Kytkin is hidden or other windows fully
//   cover it (the window's occlusion state; the poll resumes, with a fresh read, when it shows again).
// - Kytkin's own window is not a context (001 §12 W2): ContextMonitor ignores it; AppController hears about it
//   through the app's didBecomeActive / didResignActive notifications (AppEnvironment).
// - P6-0g (design v2): the window's title is the tab's name (P3), and its height follows the tab's content (P1:
//   380–640 pt, `SettingsMetrics`), the top edge staying put.

import AppKit
import SwiftUI

@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let selection = SettingsSelection()
    private let general: GeneralSettingsModel
    private let about: AboutInfo
    private let tabs: TabModels   // P2-24, P2-25
    private var window: NSWindow?
    private var tabController: SettingsTabController?
    private var hostings: [SettingsTab: NSViewController] = [:]
    /// P6-0g: each tab's natural content height, as its pane last reported it.
    private var heights: [SettingsTab: CGFloat] = [:]

    /// P2-24 Languages (via the environment) and P2-25 Rules, Convert and Apps.
    struct TabModels {
        let languages: LanguagesSettingsModel
        let rules: RulesSettingsModel
        let convert: ConvertSettingsModel
        let permissions: PermissionsSettingsModel   // P2-26
        let browsers: BrowsersSettingsModel         // P3-15
    }

    /// P2-26: General → "Show Welcome Again".
    private let showWelcome: @MainActor () -> Void
    /// P3-15: Advanced → "Open Settings Folder".
    private let openSettingsFolder: @MainActor () -> Void
    /// P6-0g: Advanced → "Copy Diagnostics".
    private let copyDiagnostics: @MainActor () -> Void

    init(general: GeneralSettingsModel, about: AboutInfo, tabs: TabModels,
         showWelcome: @escaping @MainActor () -> Void, openSettingsFolder: @escaping @MainActor () -> Void,
         copyDiagnostics: @escaping @MainActor () -> Void) {
        self.general = general
        self.about = about
        self.tabs = tabs
        self.showWelcome = showWelcome
        self.openSettingsFolder = openSettingsFolder
        self.copyDiagnostics = copyDiagnostics
        super.init()
        // P3-25: Browsers & Sites' Ask button is enabled only while that browser runs; a launch or quit while Settings
        // is open (and stays key) must show at once, not only when Settings next comes to the front.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(runningAppsChanged), name: name, object: nil)
        }
    }

    @objc private func runningAppsChanged(_ notification: Notification) {
        guard isOpen else { return }
        tabs.browsers.runningAppsChanged()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Opens Settings on `tab`, or switches an open window to it, and brings it to the front.
    func show(tab: SettingsTab) {
        general.refresh()          // fresh login-item status and layout list (R8: don’t cache the status)
        refreshTabs()
        let window = self.window ?? makeWindow()
        select(tab)
        WindowPresenter.show(window)   // P2-56
        clearInitialFocus()            // P6-0h: no focus ring on opening
        tabs.permissions.setCovered(false)   // P3-12: just brought to the front; occlusion changes follow
        updatePermissionsPolling()
    }

    /// P2-26: a grant, the tap mode or Secure Input changed (the root's display fan-out). Silent.
    func permissionsChanged() {
        guard isOpen else { return }
        tabs.permissions.reload()
    }

    /// P2-26: the 1 s permission poll runs only while the permission rows show in an open window. P6-0c: they are
    /// General's setup section and Advanced → Troubleshooting.
    private func updatePermissionsPolling() {
        tabs.permissions.setVisible(isOpen && (selection.tab == .general || selection.tab == .advanced))
    }

    /// P6-0c: the toolbar and `selection` always agree.
    private func select(_ tab: SettingsTab) {
        selection.tab = tab
        if let index = SettingsTab.allCases.firstIndex(of: tab), tabController?.selectedTabViewItemIndex != index {
            tabController?.selectedTabViewItemIndex = index
        }
        tabDidChange()
    }

    /// P6-0g: the title is the tab's name; the window takes the tab's height.
    private func tabDidChange() {
        window?.title = selection.tab.title
        resizeWindow(animated: window?.isVisible ?? false)
        updatePermissionsPolling()
        clearInitialFocus()
    }

    /// P6-0h (owner): no control gets a focus ring just because a tab opened (it was "Show Setup Again…"). AppKit picks
    /// the first key view when the window shows or a tab appears, and SwiftUI may do so a moment later, so the first
    /// responder is cleared now and once more after this run loop turn. Tab still moves the focus as usual afterwards.
    private func clearInitialFocus() {
        guard let window else { return }
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        for delay in [0.0, 0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window, Self.isUntouchedFocus(window.firstResponder, in: window) else { return }
                window.makeFirstResponder(nil)
            }
        }
    }

    /// A control focused by AppKit/SwiftUI, not a text field the user is typing in (the Rules search keeps its focus).
    private static func isUntouchedFocus(_ responder: NSResponder?, in window: NSWindow) -> Bool {
        guard let responder, responder !== window else { return false }
        if let text = responder as? NSTextView, text.isFieldEditor, !(text.string.isEmpty) { return false }
        return true
    }

    /// P6-0g: a pane reported its natural height.
    private func heightReported(_ tab: SettingsTab, _ natural: CGFloat) {
        guard natural > 0, heights[tab].map({ abs($0 - natural) > 0.5 }) ?? true else { return }
        heights[tab] = natural
        let size = contentSize(for: tab)
        hostings[tab]?.preferredContentSize = size
        if tab == selection.tab { resizeWindow(animated: window?.isVisible ?? false) }
    }

    private func contentSize(for tab: SettingsTab) -> CGSize {
        CGSize(width: SettingsMetrics.width, height: SettingsMetrics.height(for: heights[tab] ?? SettingsMetrics.minHeight))
    }

    /// Keeps the window's top edge where it is.
    private func resizeWindow(animated: Bool) {
        guard let window else { return }
        let size = contentSize(for: selection.tab)
        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: current.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated)
    }

    private func makeWindow() -> NSWindow {
        let panes = SettingsPanes(selection: selection, general: general, about: about, rules: tabs.rules,
                                  convert: tabs.convert, permissions: tabs.permissions,
                                  browsers: tabs.browsers, openSettingsFolder: openSettingsFolder,
                                  showWelcome: showWelcome, select: { [weak self] in self?.select($0) },
                                  copyDiagnostics: copyDiagnostics,
                                  reportHeight: { [weak self] tab, natural in self?.heightReported(tab, natural) })
        // P6-0c (owner 2026-11-17, visual review X4): toolbar tabs, icon over title, one hosted pane per tab.
        let controller = SettingsTabController()
        controller.tabStyle = .toolbar
        controller.canPropagateSelectedChildViewControllerTitle = false
        controller.transitionOptions = []   // P6-0g: the window controller sizes the window (top edge fixed)
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(rootView: SettingsTabPane(tab: tab, panes: panes)
                .environment(tabs.languages))   // P2-24: the Languages model goes through the environment
            hosting.sizingOptions = []
            hosting.preferredContentSize = contentSize(for: tab)
            hostings[tab] = hosting
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            controller.addTabViewItem(item)
        }
        controller.didSelect = { [weak self] index in
            guard let self, SettingsTab.allCases.indices.contains(index) else { return }
            let tab = SettingsTab.allCases[index]
            if self.selection.tab != tab { self.selection.tab = tab }
            self.tabDidChange()
        }
        tabController = controller
        let window = KytkinWindow(contentViewController: controller)   // P2-56: Esc closes it
        // QA (P2-23): no minimize. A minimized window leaves the accessory app active with no window (keys go
        // nowhere) and skips windowWillClose, so Kytkin never hides; Settings windows don't minimize anyway.
        window.styleMask = [.titled, .closable]
        window.title = selection.tab.title
        window.toolbarStyle = .preference
        window.setContentSize(contentSize(for: selection.tab))
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)   // open on the Space you’re on, not jump away
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

    /// P2-24/P2-25: layouts, layout names for Rules, and the running apps Rules can add (read only when Settings
    /// opens or comes to the front, e.g. back from System Settings → Keyboard → Input Sources).
    private func refreshTabs() {
        tabs.languages.refresh()
        tabs.rules.refresh()
        tabs.permissions.reload()
        tabs.browsers.refresh()   // P3-15 / P3-22: browsers installed since launch, this session’s statuses
    }

    func windowWillClose(_ notification: Notification) {
        tabs.permissions.setVisible(false)
        tabs.rules.settingsClosed()   // P3-24
        if let window { WindowPresenter.willClose(window) }
    }
}

/// P6-0c: reports toolbar clicks so the window controller can keep `SettingsSelection` and the permission poll in step.
@MainActor final class SettingsTabController: NSTabViewController {
    var didSelect: ((Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let tabViewItem { didSelect?(tabView.indexOfTabViewItem(tabViewItem)) }
    }
}
