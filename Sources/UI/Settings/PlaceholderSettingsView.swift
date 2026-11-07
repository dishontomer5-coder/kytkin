// P2-23: A Settings tab whose task isn't built yet shows one "coming soon" line (`SettingsTab.comingSoonText`).

import SwiftUI

struct PlaceholderSettingsView: View {
    let tab: SettingsTab

    var body: some View {
        Text(tab.comingSoonText)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding()
    }
}
