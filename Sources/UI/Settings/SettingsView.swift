// P2-23: The Settings window's content (001 §5.2), hosted in an AppKit NSWindow by SettingsWindowController
// (design.md: no SwiftUI `Settings` scene). Thin: every decision is in Core (`SettingsTab`, the tab models).
// P6-0c (owner 2026-11-17, visual review X4): no SwiftUI TabView (inside an AppKit window it drew a segmented control
// in the content and dropped the symbols). The window controller puts one `SettingsTabPane` per tab into an
// `NSTabViewController` with toolbar-style tabs; `SettingsView` (the selected tab's pane) is what the headless
// renderer draws.

import SwiftUI

/// Everything the tab panes need.
struct SettingsPanes {
    let selection: SettingsSelection
    let general: GeneralSettingsModel
    let about: AboutInfo
    let rules: RulesSettingsModel
    let convert: ConvertSettingsModel
    let apps: AppsSettingsModel
    let permissions: PermissionsSettingsModel
    let browsers: BrowsersSettingsModel
    /// Advanced → Diagnostics → "Open Settings Folder".
    let openSettingsFolder: @MainActor () -> Void
    /// General → "Show Setup Again…".
    let showWelcome: @MainActor () -> Void
    /// Switches the window to another tab (Websites → "Open Setup", "Show in Rules").
    let select: @MainActor (SettingsTab) -> Void
}

/// One tab's content, padded to the shared content inset (visual review X5).
struct SettingsTabPane: View {
    let tab: SettingsTab
    let panes: SettingsPanes
    /// The headless renderer's tall shots; nil = the window's fixed size.
    var height: CGFloat? = nil

    /// A fixed size: grouped Forms scroll and have no natural height to size the window from.
    static let size = CGSize(width: 680, height: 520)

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(width: Self.size.width, height: height ?? Self.size.height)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            GeneralSettingsView(model: panes.general, permissions: panes.permissions, showWelcome: panes.showWelcome)
        case .rules: RulesSettingsView(model: panes.rules)
        case .doubleShift: ConvertSettingsView(model: panes.convert)
        case .websites:
            BrowsersSettingsView(model: panes.browsers,
                                 openPermissions: { panes.select(.general) },
                                 showWebsiteRules: {
                                     panes.rules.kindFilter = .websites
                                     panes.select(.rules)
                                 })
        case .advanced:
            AdvancedSettingsView(selection: panes.selection, apps: panes.apps, permissions: panes.permissions,
                                 openSettingsFolder: panes.openSettingsFolder)
        case .about: AboutSettingsView(info: panes.about)
        }
    }
}

/// The selected tab's pane (the headless renderer; the real window uses one pane per toolbar tab).
struct SettingsView: View {
    let panes: SettingsPanes

    static var size: CGSize { SettingsTabPane.size }

    var body: some View {
        SettingsTabPane(tab: panes.selection.tab, panes: panes)
    }
}
