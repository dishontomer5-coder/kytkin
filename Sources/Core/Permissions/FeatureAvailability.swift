// P2-13: The single source of truth for what is on (001 §6.2 degraded modes). The UI, the KeyWatcher mode
// and the controllers all read it. Pure: grants, the tap mode actually achieved, Secure Input, settings.
//
//   Nothing granted          → app switching, pin/forget, learning by 4 s dwell
//   Input Monitoring only    → + learning by words, double-Shift toggles the language only
//   Accessibility (active)   → everything (convert, sites P3, chats P4, auto-fix P4)
//   + Automation per browser → Apple Events URL fallback / private-window detection for that browser (P3)
//   Secure Input (temporary) → switching + double-Shift toggle + dwell learning; no buffer, convert or auto-fix

import Foundation

struct FeatureAvailability: Sendable, Equatable {
    /// Per-app switching. Needs no permission (F1).
    let appSwitching: Bool
    /// Double-Shift converts text (active tap + Accessibility, not under Secure Input).
    let doubleShiftConvert: Bool
    /// Double-Shift only toggles the pair's input source (listen-only tap, no AX, or Secure Input).
    let doubleShiftToggleOnly: Bool
    /// The tap keeps a word buffer (needed for convert, auto-fix and word-confirmed learning).
    let wordBuffer: Bool
    /// RuleLearner confirms by word boundaries.
    let learningWithWords: Bool
    /// RuleLearner confirms by the 4 s dwell, whenever there is no word buffer (no tap, or Secure Input).
    let learningByDwell: Bool
    /// Site rules (AXURL, P3).
    let siteRules: Bool
    /// Chat rules (AX, P4).
    let chatRules: Bool
    /// Auto-fix (P4): active tap + Accessibility, not under Secure Input.
    let autoFix: Bool
    /// Browsers macOS allowed Automation for, when the user turned on "Use Automation" (P3-26: one global switch).
    let appleEventsBrowsers: Set<String>

    static func compute(grants: PermissionGrants, tapMode: TapMode, secureInput: Bool,
                        settings: FeatureSettings) -> FeatureAvailability {
        let on = settings.enabled
        let ax = grants.accessibility == .granted
        let tap = on && tapMode != .off
        // Swallowing, holding back and posting keys need an active tap *and* AX (a stale active mode
        // after a revoke must not keep converting).
        let canReplace = tap && tapMode == .active && ax && !secureInput
        let buffer = tap && !secureInput

        let convert = canReplace && settings.doubleShiftEnabled
        // Double-Shift uses flagsChanged, which still arrives under Secure Input (R4).
        let toggleOnly = tap && settings.doubleShiftEnabled && !convert
        let learnWords = buffer && settings.learnFromManualSwitches
        // Degrade, don't drop: without a buffer (no tap, or Secure Input) learning falls back to the dwell.
        let learnDwell = on && settings.learnFromManualSwitches && !buffer

        // Apple Events don't need Accessibility; they are the fallback when AXURL fails (R3).
        // P3-26: one global switch; every browser macOS allowed. SitePolicy keeps only those with a dictionary.
        let browsers: Set<String> = on && settings.useAutomation
            ? Set(grants.automation.filter { $0.value == .granted }.keys) : []

        return FeatureAvailability(
            appSwitching: on,
            doubleShiftConvert: convert,
            doubleShiftToggleOnly: toggleOnly,
            wordBuffer: buffer,
            learningWithWords: learnWords,
            learningByDwell: learnDwell,
            siteRules: on && ax,
            chatRules: on && ax,
            autoFix: canReplace && settings.autoFixEnabled,
            appleEventsBrowsers: browsers)
    }

    /// The tap mode KeyWatcher should try for (it reports back the mode it actually achieved):
    /// active with Accessibility, listen-only with Input Monitoring, off when no typing feature wants a tap.
    static func desiredTapMode(grants: PermissionGrants, settings: FeatureSettings) -> TapMode {
        let wantsTap = settings.enabled
            && (settings.doubleShiftEnabled || settings.autoFixEnabled || settings.learnFromManualSwitches)
        guard wantsTap else { return .off }
        if grants.accessibility == .granted { return .active }
        if grants.inputMonitoring == .granted { return .listenOnly }
        return .off
    }
}
