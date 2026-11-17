// P2-23: The Settings window's content (001 §5.2), hosted in an AppKit NSWindow by SettingsWindowController
// (design.md: no SwiftUI `Settings` scene). Thin: every decision is in Core (`SettingsTab`, the tab models).
// P6-0c (owner 2026-11-17, visual review X4): no SwiftUI TabView (inside an AppKit window it drew a segmented control
// in the content and dropped the symbols). The window controller puts one `SettingsTabPane` per tab into an
// `NSTabViewController` with toolbar-style tabs; `SettingsView` (the selected tab's pane) is what the headless
// renderer draws.
// P6-0g (design v2, P1): no fixed size any more. Each pane reports its natural height (`SettingsPage`), and the window
// sizes itself to the tab: at least 380 pt, at most 640 pt, then the tab scrolls.

import SwiftUI

/// Everything the tab panes need.
struct SettingsPanes {
    let selection: SettingsSelection
    let general: GeneralSettingsModel
    let about: AboutInfo
    let rules: RulesSettingsModel
    let convert: ConvertSettingsModel
    let permissions: PermissionsSettingsModel
    let browsers: BrowsersSettingsModel
    /// P6-0k: Settings → Statistics.
    let statistics: StatisticsSettingsModel
    /// Advanced → Troubleshooting → "Open Settings Folder".
    let openSettingsFolder: @MainActor () -> Void
    /// General → "Show Setup Again…".
    let showWelcome: @MainActor () -> Void
    /// Switches the window to another tab (Websites → "Open Setup", "Show in Rules").
    let select: @MainActor (SettingsTab) -> Void
    /// P6-0g: Advanced → "Copy Diagnostics" (a user click; the app writes the privacy-safe text to the clipboard).
    var copyDiagnostics: @MainActor () -> Void = {}
    /// P6-0g: a tab's natural content height changed (the window sizes itself to it).
    var reportHeight: @MainActor (SettingsTab, CGFloat) -> Void = { _, _ in }
}

/// One tab's content.
struct SettingsTabPane: View {
    let tab: SettingsTab
    let panes: SettingsPanes
    /// A fixed height (the headless renderer); nil = the window's.
    var height: CGFloat? = nil

    static let width = SettingsMetrics.width

    var body: some View {
        content
            .onPreferenceChange(SettingsContentHeightKey.self) { natural in
                MainActor.assumeIsolated { panes.reportHeight(tab, natural) }
            }
            .frame(width: Self.width, height: height)
            .frame(maxHeight: .infinity, alignment: .top)
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
            AdvancedSettingsView(permissions: panes.permissions, openSettingsFolder: panes.openSettingsFolder,
                                 copyDiagnostics: panes.copyDiagnostics)
        case .statistics: StatisticsSettingsView(model: panes.statistics)   // P6-0k
        case .about: AboutSettingsView(info: panes.about)
        }
    }
}

/// The selected tab's pane (the headless renderer; the real window uses one pane per toolbar tab).
struct SettingsView: View {
    let panes: SettingsPanes
    var height: CGFloat? = nil

    var body: some View {
        SettingsTabPane(tab: panes.selection.tab, panes: panes, height: height)
    }
}
