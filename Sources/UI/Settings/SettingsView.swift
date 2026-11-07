// P2-23: The Settings window's content (001 §5.2): one SwiftUI TabView, hosted in an AppKit NSWindow by
// SettingsWindowController (design.md: no SwiftUI `Settings` scene). Thin: every decision is in Core
// (`SettingsTab`, `GeneralSettingsModel`, `AboutInfo`, … `PermissionsSettingsModel`).

import SwiftUI

struct SettingsView: View {
    @Bindable var selection: SettingsSelection
    let general: GeneralSettingsModel
    let about: AboutInfo
    let rules: RulesSettingsModel        // P2-25
    let convert: ConvertSettingsModel    // P2-25
    let apps: AppsSettingsModel          // P2-25
    let permissions: PermissionsSettingsModel   // P2-26
    /// P2-26: General → "Show Welcome Again".
    let showWelcome: @MainActor () -> Void
    /// P2-26: the tab changed (the window controller turns the 1 s permission poll on or off).
    let tabChanged: @MainActor () -> Void

    /// A fixed size: grouped Forms scroll and have no natural height to size the window from.
    static let size = CGSize(width: 600, height: 460)

    var body: some View {
        TabView(selection: $selection.tab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                    .tag(tab)
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: selection.tab) { tabChanged() }
    }

    @ViewBuilder private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(model: general, showWelcome: showWelcome)
        case .about: AboutSettingsView(info: about)
        case .languages: LanguagesSettingsView()   // P2-24: its model comes from the environment
        case .rules: RulesSettingsView(model: rules)
        case .convert: ConvertSettingsView(model: convert)
        case .apps: AppsSettingsView(model: apps)
        case .permissions: PermissionsSettingsView(model: permissions)   // P2-26
        }
    }
}
