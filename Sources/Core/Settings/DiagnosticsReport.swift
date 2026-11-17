// P6-0g (design v2, Advanced P3): the text "Copy Diagnostics" puts on the clipboard for a bug report, on the user's
// click only. Privacy (CLAUDE.md invariants): only what the DEBUG trace may show: versions, setting switches,
// permission and keyboard states, and counts. Never typed text, never a website, host or address, never a rule's key or
// an app's bundle ID from the rules: rules and app settings are counted, not listed. The pair is named by Apple's layout
// IDs ("com.apple.keylayout.Hebrew"), which say nothing about the user; any other layout only as "imported layout" or
// "other layout" (P6-0g QA: an imported ID is text the user chose).

import Foundation

enum DiagnosticsReport {
    static func text(appVersion: String, macOSVersion: String, state: MenuState, prefs: Preferences,
                     importedLayoutCount: Int) -> String {
        func on(_ value: Bool) -> String { value ? "on" : "off" }
        func permission(_ state: PermissionState) -> String {
            switch state {
            case .granted: "allowed"
            case .denied: "not allowed"
            case .notDetermined: "not asked"
            case .unknown: "unknown"
            }
        }
        func tap(_ mode: TapMode) -> String {
            switch mode {
            case .off: "off"
            case .listenOnly: "listen only"
            case .active: "active"
            }
        }
        let rules = prefs.rules
        let appRules = Set(rules.compactMap { r -> RuleScope? in
            if case .app = r.scope { return RuleEngine.normalized(r.scope) } else { return nil }
        }).count
        let siteRules = Set(rules.compactMap { r -> RuleScope? in
            RuleKindFilter.websites.includes(r.scope) ? RuleEngine.normalized(r.scope) : nil
        }).count
        let pinned = rules.filter { $0.origin == .pinned }.count
        let learned = rules.filter { $0.origin == .learned }.count
        let leftAlone = prefs.apps.values.filter { $0.disabled == true }.count
        let doubleShiftOff = prefs.apps.values.filter { $0.convertEnabled == false }.count
        let menuBar = switch prefs.general.menuBarLabel {
        case .iconAndLanguage: "icon and language"
        case .iconOnly: "icon only"
        case .languageOnly: "language only"
        }
        let lines = [
            "Kytkin \(appVersion)",
            "macOS \(macOSVersion)",
            "",
            "Kytkin: \(on(prefs.general.enabled)), paused: \(state.paused ? "yes" : "no")",
            "Languages: \(layoutName(prefs.languagePair.a)) / \(layoutName(prefs.languagePair.b))",
            "Imported layouts: \(importedLayoutCount)",
            "Learn from my switches: \(on(prefs.general.learnFromManualSwitches))",
            "Menu bar: \(menuBar)",
            "",
            "Accessibility: \(permission(state.accessibility))",
            "Input Monitoring: \(permission(state.inputMonitoring))",
            "Keyboard: \(tap(state.tapMode))\(state.degradedByWatchdog ? " (lowered after a slowdown)" : "")",
            "Quit & Reopen pending: \(state.showsQuitAndReopen ? "yes" : "no")",
            "Secure typing: \(state.secureInputOn ? "active" : "not active")",
            "Other language switchers running: \(state.conflicts.runningSwitchers.count)",
            "Per-document input: \(on(state.conflicts.perDocumentInputEnabled))",
            "",
            "Double-Shift: \(on(prefs.convert.doubleShiftEnabled)), keys: \(prefs.convert.doubleShiftSides.rawValue), "
                + "\(prefs.convert.doubleShiftWindowMs) ms",
            "Switch language after converting: \(on(prefs.convert.switchLanguageAfterConvert))",
            "Work in more apps (clipboard): \(on(prefs.convert.useClipboardInUnreadableApps))",
            "Website rules: \(on(prefs.browsers.siteRulesOn)), more browsers (Automation): "
                + "\(on(prefs.browsers.useAutomation))",
            "Ignore private windows: \(on(prefs.browsers.ignorePrivateWindowsCompletely))",
            "Browser’s language in the address bar: \(on(prefs.browsers.browserLanguageInAddressBar))",
            "",
            "Rules: \(appRules) apps, \(siteRules) websites (\(pinned) always, \(learned) learned)",
            "App settings: \(prefs.apps.count) (\(leftAlone) left alone, \(doubleShiftOff) without Double-Shift)",
            "Settings file: \(state.store.isReadOnly ? "read-only" : "ok")"
                + "\(state.store.lastSaveFailed ? ", last save failed" : "")",
            "Keyboard re-enables: \(state.tapReEnableCount)",
        ]
        return lines.joined(separator: "\n")
    }

    /// P6-0g QA: only Apple's own layout IDs are named. An imported layout's ID ("user.…") is a name the user typed,
    /// and a third-party layout's ID may carry its author's or the user's name, so those are only said to be one.
    static func layoutName(_ id: InputSourceID) -> String {
        let raw = id.rawValue
        if raw.isEmpty { return "none" }
        if raw.hasPrefix(LayoutMap.userIDPrefix) { return "imported layout" }
        let apple = ["com.apple.keylayout.", "com.apple.inputmethod."]
        guard apple.contains(where: raw.hasPrefix),
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }) else {
            return "other layout"
        }
        return raw
    }
}
