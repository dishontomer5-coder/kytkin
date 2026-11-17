// P2-22: Everything the menu-bar label and menu show (001 §5.1), decided from MenuState. Pure: names come in as
// closures (the UI's cached app names and the switcher's source list), so every line, text and enabled state is
// unit-tested. StatusItemController only renders the result.
//
// Layout (P6-0c: visual review §3.3, N1–N6; flows S2, S3; copy review M-*):
//   Turn Kytkin On                                    (only while it is turned off; then no context block, no Pause)
//   <App> · <Language>                                (section header; omitted with no app yet)
//   Remembered from your switches | Always <Language> (you chose this) | No rule yet …   (grayed)
//   ✓ Always Use <current language> in <App>          (checked = that pin exists; choosing it again unpins)
//   Forget Rule for <App>                             (disabled without a matching rule)
//   ✓ Don't Convert in <App>                          (double-Shift only; the per-app switch in Advanced)
//   P3-9, on a site in a watched browser (001 §14.9): "<site> · <Language>", "Always Use … on <site>",
//   "Forget Rule for <site>" (enabled only for a matched site or subdomain rule, D6).
//   Pause Kytkin | Resume Kytkin
//   ── ⚠ warnings, only when any apply (MenuWarning order): one clickable line each, the fix as its subtitle ──
//   Settings…  ⌘,                                     (disabled until the Settings window exists, P2-23)
//   About Kytkin                                      (only with Settings; the version lives in About)
//   ── DEBUG lines + "DEBUG: Switch to ▸" (Debug builds only) ──
//   Quit Kytkin  ⌘Q
//
// User-visible texts are plain English with no implementation words (no "tap", "TIS"); DEBUG lines may use them.
// Menu items use Title Case, grayed info lines sentence case (copy review rule 6).

import Foundation

enum MenuModel {
    /// The menu-bar item (P6-0c, visual review §3.1–§3.2, copy review M-1/M-2, owner 2026-11-17). `StatusItemController`
    /// sets it only when it differs (P2-52 item 4).
    struct Label: Hashable {
        /// Priority when several apply: off > paused > attention > active. The glyph changes with it; the letters
        /// don't (no colour, no animation: the letter change is the feedback).
        enum Look: String, Hashable, CaseIterable {
            case active, paused, attention, off
        }

        let look: Look
        /// P6-0e (docs/design/artwork/Colors.md): the filled half of the logo is the language that is on: `.a` = the
        /// pair's first language (left half), `.b` = the second. Not one of the pair: `.a`.
        var side: PairSide = .a
        /// "HE"; nil when the language is unknown (copy review M-1: no "?") or in icon-only mode.
        let letters: String?
        /// The Kytkin glyph is drawn. Always in letters-only mode when there are no letters, so the item never
        /// disappears.
        let showsIcon: Bool
        /// VoiceOver: "Kytkin, Hebrew", "Kytkin, Hebrew, paused", "Kytkin, Hebrew, needs attention",
        /// "Kytkin, Hebrew, turned off"; "Kytkin" when the language is unknown.
        let accessibilityLabel: String

        /// Paused and off look dimmed (P6-0e: the artwork draws it: paused fill 45 %, off 35 %).
        var dimmed: Bool { look == .paused || look == .off }

        /// P6-0e (Colors.md): the letters fade to 35 % only when Kytkin is off.
        var lettersOpacity: Double { look == .off ? 0.35 : 1 }

        /// The glyph's asset name (`Resources/MenuBar/kytkin-menubar-{active,paused,attention,off}-{a,b}.pdf`).
        var imageName: String { MenuModel.glyphName(look, side: side) }

        /// P6-0e QA: Settings → General → "Show in menu bar" (decides the item's width, not what is known).
        var display: Preferences.General.MenuBarLabel = .iconAndLanguage
    }

    /// P6-0e QA: the status item's fixed layout (pt). The width depends on the display mode only, never on the
    /// language, its letters being known, the look or a warning: the items beside Kytkin never move.
    enum ItemLayout {
        static let glyphWidth: Double = 18
        static let gap: Double = 4
        static let lettersWidth: Double = 20
        /// Letters-only mode: room for the "needs attention" dot after the letters, kept even without one.
        static let dotRoom: Double = 8

        static func width(for display: Preferences.General.MenuBarLabel) -> Double {
            switch display {
            case .iconAndLanguage: glyphWidth + gap + lettersWidth
            case .iconOnly: glyphWidth
            case .languageOnly: lettersWidth + dotRoom
            }
        }
    }

    /// P6-0e: the menu-bar glyph assets, one per look and pair side (Resources/MenuBar/README.md).
    static func glyphName(_ look: Label.Look, side: PairSide) -> String {
        "kytkin-menubar-\(look.rawValue)-\(side == .a ? "a" : "b")"
    }

    /// P6-0e: which half of the logo is filled: the pair member whose input source is selected.
    static func side(of current: InputSourceID?, in pair: LanguagePair?) -> PairSide {
        guard let current, let pair else { return .a }
        return current == pair.b && current != pair.a ? .b : .a
    }

    static func label(languageCode: String?, languageName: String? = nil, state: MenuState,
                      display: Preferences.General.MenuBarLabel = .iconAndLanguage,
                      current: InputSourceID? = nil) -> Label {
        let look: Label.Look
        if !state.enabled {
            look = .off
        } else if state.paused {
            look = .paused
        } else if MenuWarning.list(for: state).contains(where: { $0.marksLabel }) {
            look = .attention
        } else {
            look = .active
        }
        let code = InputSourceLabel.label(forLanguages: [languageCode ?? ""])
        let known = code == InputSourceLabel.unknown ? nil : code
        let letters = display == .iconOnly ? nil : known
        let showsIcon = display != .languageOnly || letters == nil
        var spoken = "Kytkin"
        if known != nil, let name = languageName ?? known { spoken += ", \(name)" }
        switch look {
        case .active: break
        case .paused: spoken += ", paused"
        case .attention: spoken += ", needs attention"
        case .off: spoken += ", turned off"
        }
        return Label(look: look, side: side(of: current, in: state.pairInputSources), letters: letters,
                     showsIcon: showsIcon, accessibilityLabel: spoken, display: display)
    }

    /// The whole menu, top to bottom.
    /// - currentSource: the selected input source (nil if unknown: Pin is disabled).
    /// - sourceName: display name for a rule's source ("Hebrew"); falls back to the raw id in the caller.
    /// - appName: display name for a bundle ID ("Notes"); the UI caches it.
    /// - settingsAvailable: the Settings window hook is set (P2-23). Without it "Settings…" is disabled and the
    ///   "Open Settings…" hints and About are hidden.
    static func items(state: MenuState, currentSource: InputSourceInfo?, version: String, settingsAvailable: Bool,
                      includeDebug: Bool, sourceName: (InputSourceID) -> String,
                      appName: (String) -> String) -> [MenuItemModel] {
        var out: [MenuItemModel] = []
        if !state.enabled {
            // P6-0c (visual review N2, copy M-10): one click turns it back on; nothing else applies while it is off.
            out.append(.action("Turn Kytkin On", .turnOn))
        } else {
            let context = contextItems(state: state, currentSource: currentSource, sourceName: sourceName,
                                       appName: appName)
            if !context.isEmpty { out += context + [.separator] }
            out.append(.action(state.paused ? "Resume Kytkin" : "Pause Kytkin", .togglePause))
        }

        let warnings = MenuWarning.list(for: state).filter { $0 != .kytkinOff }
        if !warnings.isEmpty {
            out.append(.separator)
            for w in warnings { out.append(item(for: w, settingsAvailable: settingsAvailable)) }
        }

        // P6-3: the optional update check found a newer release (a plain line, not a warning).
        if let update = state.updateNotice {
            out.append(.separator)
            out.append(.action(update.menuTitle, .openURL(update.pageURL)))
        }

        out.append(.separator)
        out.append(.action("Settings…", .openSettings(.general), enabled: settingsAvailable, key: ","))
        // P6-0c (visual review N6): "About Kytkin"; the version lives in About.
        out.append(settingsAvailable ? .action("About Kytkin", .openSettings(.about)) : .info("Kytkin v\(version)"))

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

    // MARK: - Context, Pin, Forget, Don't Convert

    /// P6-0c: the block about the app (or website) in front. Empty with no app yet (copy review M-3).
    static func contextItems(state: MenuState, currentSource: InputSourceInfo?,
                             sourceName: (InputSourceID) -> String,
                             appName: (String) -> String) -> [MenuItemModel] {
        guard let rule = state.currentRule else { return [] }
        let c = rule.context
        let resolution = rule.resolution
        let isSite = rule.isSite
        let here: String
        if isSite, case .siteHost(let host)? = resolution.matched?.scope {
            here = HostNormalizer.unicodeForm(HostNormalizer.normalize(host))
        } else {
            here = scopeName(rule.pinScope, appName: appName)
        }
        let appTitle = appName(c.bundleID)

        // The language shown: the rule's, else what is selected now.
        let language = (resolution.matched?.inputSource ?? resolution.target).map(sourceName)
            ?? currentSource?.name
        var head = language.map { "\(here) · \($0)" } ?? here
        if isSite, c.isPrivateWindow == true { head += " (private)" }

        // P6-0c (flows S2, copy M-4…M-6): plain words for where the language comes from.
        let why: String
        if let matched = resolution.matched {
            switch matched.scope {
            case .app where isSite: why = "The browser's language"
            case .app, .site, .siteHost, .chat:
                why = matched.origin == .pinned ? "Always \(sourceName(matched.inputSource)) (you chose this)"
                                                : "Remembered from your switches"
            }
        } else if resolution.level == .addressBar {
            why = "Address bar: the browser's language"   // P3-29
        } else if resolution.level == .defaultRule {
            why = "No rule yet, so the default applies"
        } else {
            why = "No rule yet"
        }

        let forget: MenuItemModel = rule.forgetScope.map {
            .action("Forget Rule for \(isSite ? here : scopeName($0, appName: appName))", .forgetCurrent)
        } ?? .action("Forget Rule for \(here)", .forgetCurrent, enabled: false)

        // P6-0c (flows S3; owner: double-Shift only): the per-app convert switch (Advanced → App Exceptions).
        let dontConvert = MenuItemModel.action("Don't Convert in \(appTitle)", .toggleConvertInCurrentApp,
                                               checked: state.convertOffInCurrentApp)

        return [.header(head), .info(why),
                pinItem(rule, currentSource: currentSource, preposition: isSite ? "on" : "in", here: here),
                forget, dontConvert]
    }

    /// "Always Use <language> in|on <here>": checked once exactly that pin exists; choosing it again unpins it
    /// (visual review N5: never checked and greyed).
    private static func pinItem(_ rule: SwitchController.CurrentRule, currentSource: InputSourceInfo?,
                                preposition: String, here: String) -> MenuItemModel {
        guard let current = currentSource else {
            return .action("Always Use This Language \(preposition) \(here)", .pinCurrent, enabled: false)
        }
        // P3-9: compare normalized scopes, so an old hand-edited Unicode key still reads as "this pin".
        let done = rule.resolution.matched.map {
            $0.origin == .pinned && RuleEngine.normalized($0.scope) == RuleEngine.normalized(rule.pinScope)
                && $0.inputSource == current.id
        } ?? false
        return .action("Always Use \(current.name) \(preposition) \(here)", done ? .unpinCurrent : .pinCurrent,
                       checked: done)
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

    /// P6-0c (visual review N1, copy review M-11…M-21): one line per warning with a ⚠ symbol. It is clickable when
    /// there is something to do (the subtitle says what); a warning with nothing to do stays an info line.
    static func item(for warning: MenuWarning, settingsAvailable: Bool) -> MenuItemModel {
        let warn = MenuItemModel.warningSymbol
        func open(_ title: String, _ target: MenuItemModel.SettingsTarget, _ subtitle: String) -> MenuItemModel {
            settingsAvailable ? .action(title, .openSettings(target), symbol: warn, subtitle: subtitle)
                              : .info(title, symbol: warn)
        }
        switch warning {
        case .kytkinOff:
            return .action("Turn Kytkin On", .turnOn)
        case .quitAndReopen:
            return .action("Quit & Reopen Kytkin to finish setup", .quitAndReopen, symbol: warn,
                           subtitle: "Kytkin opens again by itself")
        case .accessibilityNeeded(let toggleStillWorks):
            // P6-0c (flows M3): websites need it too.
            return open(toggleStillWorks ? "Double-Shift can't convert: Accessibility is off"
                                         : "Double-Shift and website rules are off: Accessibility is off",
                        .permissions, "Allow Accessibility…")
        case .otherSwitchers(let names):
            // Owner 2026-11-17: a warning only; Settings explains.
            return open("\(joined(names)) also switch\(names.count == 1 ? "es" : "") languages", .general,
                        names.count == 1 ? "Quit it so the two don't undo each other" : "Quit them so they don't undo Kytkin")
        case .perDocumentInput:
            // P6-0c (copy review M-14, P1): the old menu path was wrong; Settings shows the right steps.
            return open("Not learning: macOS is switching languages per document", .permissions, "How to Turn It Off…")
        case .keyboardSlowedDown(let canRestart):
            return canRestart
                ? .action("Double-Shift stopped after a slowdown", .restartKeyboard, symbol: warn,
                          subtitle: "Start Double-Shift Again")
                : .info("Double-Shift stopped after a slowdown", symbol: warn)
        case .keyboardFeaturesOff(let canRestart):
            return canRestart
                ? .action("Double-Shift is off", .restartKeyboard, symbol: warn, subtitle: "Start Double-Shift Again")
                : .info("Double-Shift is off", symbol: warn)
        case .secureInput:
            return .info("Double-Shift waits: another app is protecting your typing", symbol: warn)
        case .settingsReadOnly(let newerVersion):
            return open(newerVersion ? "Settings are from a newer Kytkin" : "Settings couldn't be read",
                        .general, newerVersion ? "Update Kytkin to change them" : "Kytkin is using the defaults")
        case .saveFailed:
            return .info("Settings couldn't be saved. Changes last until you quit.", symbol: warn)
        case .settingsPartlyReset(let original):
            guard let original else { return .info("Some settings couldn't be read and were reset", symbol: warn) }
            return .action("Some settings couldn't be read and were reset", .revealFile(original), symbol: warn,
                           subtitle: "Show Original File")
        case .settingsReset(let movedTo):
            return .action("Settings were damaged, so Kytkin started fresh", .revealFile(movedTo), symbol: warn,
                           subtitle: "Show Old File")
        }
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
