// P2-23: Which Settings tab is showing. The window controller sets it from `openSettings(tab:)` (the menu's hook)
// and from the toolbar (P6-0c: `NSTabViewController`); the tab panes read it.
// P6-0g (design v2): Advanced is one pane (no inner tabs), so the tab is all there is.

import Foundation
import Observation

@MainActor @Observable final class SettingsSelection {
    var tab: SettingsTab

    init(tab: SettingsTab = .general) {
        self.tab = tab
    }
}
