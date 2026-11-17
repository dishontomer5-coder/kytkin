// P2-23: Which Settings tab is showing. The window controller sets it from `openSettings(tab:)` (the menu's hook)
// and from the toolbar (P6-0c: `NSTabViewController`); the tab panes read it.

import Foundation
import Observation

@MainActor @Observable final class SettingsSelection {
    var tab: SettingsTab
    /// P6-0c: the part of the Advanced tab showing.
    var advancedSection: AdvancedSection

    init(tab: SettingsTab = .general, advancedSection: AdvancedSection = .apps) {
        self.tab = tab
        self.advancedSection = advancedSection
    }
}
