// P2-22: Everything the menu-bar label and menu show (001 §5.1), decided from MenuState. Pure: names come in as
// closures (the UI's cached app names and the switcher's source list), so every line, text and enabled state is
// unit-tested. StatusItemController only renders the result.
//
// Layout:
//   <App>: <Language> (learned|pinned|default) | <App>: no rule | No app yet      (grayed)
//   Always use <current language> in <App>            (checked + disabled when that pin already exists)
//   Forget rule for <App>                             (disabled without a matching rule)
//   P3-9, on a site in a watched browser (001 §14.9), the three lines become:
//   <site> (<Browser>[, private]): <Language> (learned|pinned|<Browser>'s rule|default) | <site> (<Browser>): no rule
//   Always use <current language> on <site>
//   Forget rule for <site>                            (enabled only for a matched site or subdomain rule, D6)
//   Pause Kytkin | Resume Kytkin
//   ── warnings, only when any apply (MenuWarning order), each with indented hints/actions ──
//   Settings…  ⌘,                                     (disabled until the Settings window exists, P2-23)
//   About Kytkin v<version> | Kytkin v<version>       (About only with Settings)
//   ── DEBUG lines + "DEBUG: Switch to ▸" (Debug builds only) ──
//   Quit Kytkin  ⌘Q
//
// User-visible texts are plain English with no implementation words (no "tap", "TIS"); DEBUG lines may use them.

import Foundation

enum MenuModel {
    /// The menu-bar button. `title` changes only when the language, Pause or the warning dot changes, so the
    /// UI sets it only when it differs (P2-52 item 4).
    struct Label: Equatable {
        let title: String
        /// Paused: the button is drawn grayed as well as carrying the dot.
        let dimmed: Bool
    }

    /// 001 §5.1: the language code, plus a small dot while paused or while a warning (other than Secure Input) applies.
    static func label(languageCode: String?, state: MenuState) -> Label {
        let code = InputSourceLabel.label(forLanguages: [languageCode ?? ""])
        let marked = state.paused || MenuWarning.list(for: state).contains { $0.marksLabel }
        return Label(title: marked ? code + dot : code, dimmed: state.paused)
    }

    static let dot = "·"

    /// The whole menu, top to bottom.
    /// - currentSource: the selected input source (nil if unknown: Pin is disabled).
    /// - sourceName: display name for a rule's source ("Hebrew"); falls back to the raw id in the caller.
    /// - appName: display name for a bundle ID ("Notes"); the UI caches it.
    /// - settingsAvailable: the Settings window hook is set (P2-23). Without it "Settings…" is disabled and the
    ///   "Open Settings…" hints and About are hidden.
    static func items(state: MenuState, currentSource: InputSourceInfo?, version: String, settingsAvailable: Bool,
                      includeDebug: Bool, sourceName: (InputSourceID) -> String,
                      appName: (String) -> String) -> [MenuItemModel] {
        var out = contextItems(state: state, currentSource: currentSource, sourceName: sourceName, appName: appName)
        out.append(.action(state.paused ? "Resume Kytkin" : "Pause Kytkin", .togglePause))

        let warnings = MenuWarning.list(for: state)
        if !warnings.isEmpty {
            out.append(.separator)
            for w in warnings { out += items(for: w, settingsAvailable: settingsAvailable) }
        }

        out.append(.separator)
        out.append(.action("Settings…", .openSettings(.general), enabled: settingsAvailable, key: ","))
        out.append(settingsAvailable ? .action("About Kytkin v\(version)", .openSettings(.about))
                                     : .info("Kytkin v\(version)"))

        // P2-27: compiled out of Release, so its binary carries no DEBUG lines at all (not just hidden ones).
        #if DEBUG
        if includeDebug {
            // P2-14 / P2-17 checklist tools. Counts and states, never keys.
            out.append(.separator)
            out.append(.info("DEBUG: Keyboard: \(state.tapMode)\(state.degradedByWatchdog ? " (lowered)" : "")"))
            out.append(.info("DEBUG: Double-Shift count: \(state.doubleShiftCount)"))
            out.append(.info("DEBUG: Tap re-enables: \(state.tapReEnableCount)"))
            // P2-27 (001 §7 B1): tap callbacks over 1 ms, the on-device check of the callback budget.
            out.append(.info("DEBUG: Slow key callbacks (over 1 ms): \(state.slowCallbackCount)"))
            // P2-55: the learner's gate, candidate and last decision (IDs and reasons only).
            if let line = state.learnerDebug { out.append(.info("DEBUG: \(line)")) }
            // P3-14: the browser watch (001 §14.12 "Site reads" line; states and counts only, never a host).
            if let line = state.siteDebug { out.append(.info("DEBUG: \(line)")) }
            out.append(MenuItemModel(kind: .debugSwitchSubmenu, title: "DEBUG: Switch to", isEnabled: true,
                                     isChecked: false, indent: 0, keyEquivalent: ""))
        }
        #endif

        out.append(.separator)
        out.append(.action("Quit Kytkin", .quit, key: "q"))
        return out
    }

    // MARK: - Context, Pin, Forget

    static func contextItems(state: MenuState, currentSource: InputSourceInfo?,
                             sourceName: (InputSourceID) -> String,
                             appName: (String) -> String) -> [MenuItemModel] {
        guard let rule = state.currentRule else { return [.info("No app yet")] }
        if rule.isSite {
            return siteContextItems(rule, currentSource: currentSource, sourceName: sourceName, appName: appName)
        }
        let resolution = rule.resolution
        let here = scopeName(rule.pinScope, appName: appName)

        let line: String
        if let matched = resolution.matched {
            line = "\(scopeName(matched.scope, appName: appName)): \(sourceName(matched.inputSource)) "
                + "(\(matched.origin.rawValue))"
        } else if resolution.level == .addressBar, let target = resolution.target {
            line = "\(here): \(sourceName(target)) (address bar)"   // P3-29
        } else if resolution.level == .defaultRule, let target = resolution.target {
            line = "\(here): \(sourceName(target)) (default)"
        } else {
            line = "\(here): no rule"
        }

        let forget: MenuItemModel = rule.forgetScope.map {
            .action("Forget rule for \(scopeName($0, appName: appName))", .forgetCurrent)
        } ?? .action("Forget rule for \(here)", .forgetCurrent, enabled: false)

        return [.info(line), pinItem(rule, currentSource: currentSource, preposition: "in", here: here), forget]
    }

    /// P3-9 (001 §14.9): the site form. `S` = the matched host for a siteHost match, else the site (both in Unicode);
    /// `B` = the browser's name, plus ", private" in a private window. Pin says "on <site>"; Forget names the site and
    /// is enabled only for a matched site or siteHost rule (D6).
    private static func siteContextItems(_ rule: SwitchController.CurrentRule, currentSource: InputSourceInfo?,
                                         sourceName: (InputSourceID) -> String,
                                         appName: (String) -> String) -> [MenuItemModel] {
        let c = rule.context
        let resolution = rule.resolution
        let site: String
        if case .siteHost(let host)? = resolution.matched?.scope {
            site = HostNormalizer.unicodeForm(HostNormalizer.normalize(host))
        } else {
            site = scopeName(rule.pinScope, appName: appName)
        }
        let browser = appName(c.bundleID)
        let head = "\(site) (\(browser)\(c.isPrivateWindow == true ? ", private" : ""))"

        let line: String
        if let matched = resolution.matched {
            let why: String
            switch matched.scope {
            case .app: why = "\(browser)'s rule"
            case .site, .siteHost, .chat: why = matched.origin.rawValue
            }
            line = "\(head): \(sourceName(matched.inputSource)) (\(why))"
        } else if resolution.level == .addressBar, let target = resolution.target {
            line = "\(head): \(sourceName(target)) (address bar)"   // P3-29: the browser's language in the bar
        } else if resolution.level == .defaultRule, let target = resolution.target {
            line = "\(head): \(sourceName(target)) (default)"
        } else {
            line = "\(head): no rule"
        }

        let forget: MenuItemModel = .action("Forget rule for \(site)", .forgetCurrent, enabled: rule.forgetScope != nil)
        return [.info(line), pinItem(rule, currentSource: currentSource, preposition: "on", here: site), forget]
    }

    /// "Always use <language> in|on <here>", checked and disabled once exactly that pin exists.
    private static func pinItem(_ rule: SwitchController.CurrentRule, currentSource: InputSourceInfo?,
                                preposition: String, here: String) -> MenuItemModel {
        guard let current = currentSource else {
            return .action("Always use this language \(preposition) \(here)", .pinCurrent, enabled: false)
        }
        // P3-9: compare normalized scopes, so an old hand-edited Unicode key still reads as "this pin".
        let done = rule.resolution.matched.map {
            $0.origin == .pinned && RuleEngine.normalized($0.scope) == RuleEngine.normalized(rule.pinScope)
                && $0.inputSource == current.id
        } ?? false
        return .action("Always use \(current.name) \(preposition) \(here)", .pinCurrent, enabled: !done, checked: done)
    }

    /// How a rule's scope is named in the menu: the app's name, the site, or the chat (P3/P4).
    /// P3-9 (D13): hosts are stored in Punycode and shown in Unicode (`HostNormalizer.unicodeForm`).
    static func scopeName(_ scope: RuleScope, appName: (String) -> String) -> String {
        switch scope {
        case .app(let bundleID): appName(bundleID)
        case .site(let domain): HostNormalizer.unicodeForm(HostNormalizer.normalize(domain))
        case .siteHost(let host): HostNormalizer.unicodeForm(HostNormalizer.normalize(host))
        case .chat(let bundleID, _): "this chat in \(appName(bundleID))"
        }
    }

    // MARK: - Warnings

    static func items(for warning: MenuWarning, settingsAvailable: Bool) -> [MenuItemModel] {
        let openSettings: (MenuItemModel.SettingsTarget) -> [MenuItemModel] = { target in
            settingsAvailable ? [.action("Open Settings…", .openSettings(target), indent: 1)] : []
        }
        switch warning {
        case .kytkinOff:
            return [.info("Kytkin is turned off")] + openSettings(.general)
        case .quitAndReopen:
            return [.info("Quit and reopen Kytkin to finish setup"),
                    .action("Quit & Reopen", .quitAndReopen, indent: 1)]
        case .accessibilityNeeded(let toggleStillWorks):
            let text = toggleStillWorks ? "Accessibility is off: double-Shift only switches the language"
                                        : "Accessibility is off: double-Shift doesn't work"
            return [.info(text)] + openSettings(.permissions)
        case .otherSwitchers(let names):
            let one = names.count == 1
            return [.info("\(joined(names)) \(one ? "is" : "are") also switching languages"),
                    .info(one ? "Quit it so the two don't fight" : "Quit them so they don't fight", indent: 1)]
        case .perDocumentInput:
            return [.info("Learning paused: macOS switches language per document"),
                    .info("Turn it off in System Settings → Keyboard → Input Sources", indent: 1)]
        case .keyboardSlowedDown(let canRestart):
            var out: [MenuItemModel] = [.info("Some keyboard features stopped after a slowdown")]
            if canRestart { out.append(.action("Restart Keyboard Features", .restartKeyboard, indent: 1)) }
            return out
        case .keyboardFeaturesOff(let canRestart):
            var out: [MenuItemModel] = [.info("Some keyboard features are off")]
            if canRestart { out.append(.action("Restart Keyboard Features", .restartKeyboard, indent: 1)) }
            return out
        case .secureInput:
            return [.info("Typing protected by another app")]
        case .settingsReadOnly(let newerVersion):
            return [.info(newerVersion ? "Settings are from a newer Kytkin: changes won't be saved"
                                       : "Settings file couldn't be read: changes won't be saved")]
        case .saveFailed:
            return [.info("Couldn't save settings")]
        case .settingsPartlyReset(let original):
            var out: [MenuItemModel] = [.info("Some settings couldn't be read and were reset")]
            if let original { out.append(.action("Show Original File", .revealFile(original), indent: 1)) }
            return out
        case .settingsReset(let movedTo):
            return [.info("Settings file was damaged and was reset"),
                    .action("Show Damaged File", .revealFile(movedTo), indent: 1)]
        }
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
