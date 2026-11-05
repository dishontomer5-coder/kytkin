// P2-13: The user switches FeatureAvailability reads. A plain value, so this pure Core type doesn't depend on
// P2-8's `Preferences`; the composition root fills it from `general`, `convert`, `autoFix` and `browsers`.
// Defaults match 001 §4.2.

import Foundation

struct FeatureSettings: Sendable, Equatable {
    var enabled = true                       // general.enabled
    var learnFromManualSwitches = true       // general.learnFromManualSwitches
    var doubleShiftEnabled = true            // convert.doubleShiftEnabled
    var autoFixEnabled = true                // autoFix.enabled (P4)
    var appleEventsOptIn: Set<String> = []   // browsers.appleEventsOptIn where true (P3)

    init(enabled: Bool = true, learnFromManualSwitches: Bool = true, doubleShiftEnabled: Bool = true,
         autoFixEnabled: Bool = true, appleEventsOptIn: Set<String> = []) {
        self.enabled = enabled
        self.learnFromManualSwitches = learnFromManualSwitches
        self.doubleShiftEnabled = doubleShiftEnabled
        self.autoFixEnabled = autoFixEnabled
        self.appleEventsOptIn = appleEventsOptIn
    }
}
