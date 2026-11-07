// P2-23: Which Settings tab is showing. The window controller sets it from `openSettings(tab:)` (the menu's hook);
// the SwiftUI TabView binds to it.

import Foundation
import Observation

@MainActor @Observable final class SettingsSelection {
    var tab: SettingsTab

    init(tab: SettingsTab = .general) { self.tab = tab }
}
