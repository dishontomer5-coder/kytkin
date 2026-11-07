// P2-20: Pure mappings from Preferences into the plain values other Core types take, so those types never depend
// on Preferences (001 §2.2): the tap processor config (P2-50, §12 W6), FeatureSettings (P2-13) and the per-app
// MethodHint overrides (§12 T5).

import Foundation

enum PreferencesMapping {
    // MARK: - KeyProcessorConfig (P2-50)

    /// Ranges every runtime config is clamped to before `KeyWatcher.perform(.updateConfig)` or the processor init,
    /// so a hand-edited or future value can never make typing wait longer than the 001 §7 budgets.
    static let doubleShiftWindowRangeMs: ClosedRange<UInt64> = 200...500   // P2-31
    static let maxHoldRangeNanos: ClosedRange<UInt64> = 50_000_000...500_000_000
    static let convertDeadlineRangeNanos: ClosedRange<UInt64> = 50_000_000...400_000_000    // B2
    static let autoFixDeadlineRangeNanos: ClosedRange<UInt64> = 20_000_000...150_000_000    // B2
    static let hardCapRangeNanos: ClosedRange<UInt64> = 100_000_000...1_000_000_000         // B3

    static func processorConfig(_ prefs: Preferences) -> KeyProcessorConfig {
        var c = KeyProcessorConfig()
        c.doubleShift = prefs.convert.doubleShiftConfig
        c.doubleShiftEnabled = prefs.convert.doubleShiftEnabled
        // P2-20: auto-fix doesn't exist until P4 (P4-7). With it on, the processor would hold every Space after a word
        // for 150 ms with no worker to finish it, so it stays off whatever `autoFix.enabled` says.
        c.autoFixEnabled = false
        return clamped(c)
    }

    static func clamped(_ config: KeyProcessorConfig) -> KeyProcessorConfig {
        var c = config
        let windowRange = doubleShiftWindowRangeMs.lowerBound * 1_000_000...doubleShiftWindowRangeMs.upperBound * 1_000_000
        c.doubleShift.windowNanos = clamp(c.doubleShift.windowNanos, windowRange)
        c.doubleShift.maxHoldNanos = clamp(c.doubleShift.maxHoldNanos, maxHoldRangeNanos)
        c.convertDeadlineNanos = clamp(c.convertDeadlineNanos, convertDeadlineRangeNanos)
        c.autoFixDeadlineNanos = clamp(c.autoFixDeadlineNanos, autoFixDeadlineRangeNanos)
        c.postingHardCapNanos = clamp(c.postingHardCapNanos, hardCapRangeNanos)
        c.holdBackCapacity = min(max(c.holdBackCapacity, 1), HoldBackQueue.maxCapacity)
        return c
    }

    private static func clamp(_ v: UInt64, _ r: ClosedRange<UInt64>) -> UInt64 {
        min(max(v, r.lowerBound), r.upperBound)
    }

    // MARK: - FeatureSettings (P2-13)

    /// `paused` is the session-only Pause from the menu: it turns everything off like `general.enabled == false`,
    /// without writing the preference.
    static func featureSettings(_ prefs: Preferences, paused: Bool) -> FeatureSettings {
        FeatureSettings(enabled: prefs.general.enabled && !paused,
                        learnFromManualSwitches: prefs.general.learnFromManualSwitches,
                        doubleShiftEnabled: prefs.convert.doubleShiftEnabled,
                        // P2-20: off until P4, as in `processorConfig` (it would also make a tap "wanted").
                        autoFixEnabled: false,
                        useAutomation: prefs.browsers.useAutomation)
    }

    // MARK: - MethodHint overrides (001 §12 T5)

    /// `disabled == true` or `convertEnabled == false` → `.disabled`; otherwise `replacementMethod` → the hint of the
    /// same name; nothing set → no override (the seed or `.auto` applies). `autoFixEnabled` stays separate (P4).
    static func methodHint(_ o: Preferences.AppOverride) -> MethodHint? {
        if o.disabled == true || o.convertEnabled == false { return .disabled }
        guard let method = o.replacementMethod else { return nil }
        switch method {
        case .auto: return .auto
        case .keysOnly: return .keysOnly
        case .noUnicode: return .noUnicode
        case .preferPaste: return .preferPaste
        case .terminal: return .terminal
        }
    }

    static func methodHintOverrides(_ apps: [String: Preferences.AppOverride]) -> [String: MethodHint] {
        apps.compactMapValues(methodHint)
    }
}
