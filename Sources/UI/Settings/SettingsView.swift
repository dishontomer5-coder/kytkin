// P2-23: The Settings window's content (001 §5.2): one SwiftUI TabView, hosted in an AppKit NSWindow by
// SettingsWindowController (design.md: no SwiftUI `Settings` scene). Thin: every decision is in Core
// (`SettingsTab`, `GeneralSettingsModel`, `AboutInfo`). Later tasks replace a placeholder with their own view.

import SwiftUI

struct SettingsView: View {
    @Bindable var selection: SettingsSelection
    let general: GeneralSettingsModel
    let about: AboutInfo

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
    }

    @ViewBuilder private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(model: general)
        case .about: AboutSettingsView(info: about)
        default: PlaceholderSettingsView(tab: tab)
        }
    }
}
