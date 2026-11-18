// P2-22: Everything the menu-bar label and menu show (001 §5.1), decided from MenuState. Pure: names come in as
// closures (the UI's cached app names and the switcher's source list), so every line, text and enabled state is
// unit-tested. StatusItemController only renders the result.
//
// Layout (P6-0g, design v2 review "Menu-bar menu" and lg-menu; earlier P6-0f, P6-0c):
//   Turn Kytkin On                                    (only while it is turned off; then no context block, no Pause)
//   In <App>                                          (section header; "On <site>" on a website; omitted with no app)
//   Always use        [EN | HE]                       (the Kytkin key: the filled half = the pinned pair language;
//                                                      a click on the other half pins it, on the filled half unpins)
//   ✓ Follow My Last Switch                           (checked = no pin here: the learned rule follows your switches)
//   ──
//   ✓ Turn Off Double-Shift in <App>                  (the per-app switch, Rules' Double-Shift column)
//   Forget Rule for <App>                             (only when a learned or pinned rule matches)
//   P3-9, on a site in a watched browser (001 §14.9): the same for the site ("Forget Rule for <site>" only for a
//   matched site or subdomain rule, D6).
//   ── ⚠ warnings, only when any apply (MenuWarning order): one clickable line each, the fix as its subtitle;
//      then "Update available: …" when "Keep Kytkin up to date" found one ──
//   Pause Kytkin | Resume Kytkin
//   Settings…  ⌘,                                     (disabled until the Settings window exists, P2-23)
//   ── Debug ▸ (Debug builds only, and only when the menu is opened with Option-click) ──
//   Quit Kytkin  ⌘Q
// One left inset for every item (review P3): no indentation.
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
        /// P6-0g (review P3): 5 pt from the icon to "EN".
        static let gap: Double = 5
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
    ///   "Open Settings…" hints are hidden.
    /// - sourceCode: P6-0g, the letters for a language ("EN"), from its input source's language; nil = the first two
    ///   letters of its name.
    static func items(state: MenuState, currentSource: InputSourceInfo?, settingsAvailable: Bool,
                      includeDebug: Bool, sourceName: (InputSourceID) -> String,
                      sourceCode: (InputSourceID) -> String? = { _ in nil },
                      appName: (String) -> String) -> [MenuItemModel] {
        // P6-0f: the menu is built from sections; a separator goes only between non-empty ones.
        var sections: [[MenuItemModel]] = []
        if !state.enabled {
            // P6-0c (visual review N2, copy M-10): one click turns it back on; nothing else applies while it is off.
            sections.append([.action("Turn Kytkin On", .turnOn)])
        } else {
            sections += contextSections(state: state, currentSource: currentSource, sourceName: sourceName,
                                        sourceCode: sourceCode, appName: appName)
        }

        var notices = MenuWarning.list(for: state).filter { $0 != .kytkinOff }
            .map { item(for: $0, settingsAvailable: settingsAvailable) }
        // P6-3, P4-3: a quiet update check found a newer version (a plain line, not a warning).
        if let update = state.updateNotice { notices.append(.action(update.menuTitle, .showUpdate)) }
        sections.append(notices)

        var controls: [MenuItemModel] = []
        if state.enabled { controls.append(.action(state.paused ? "Resume Kytkin" : "Pause Kytkin", .togglePause)) }
        controls.append(.action("Settings…", .openSettings(.general), enabled: settingsAvailable, key: ","))
        sections.append(controls)

        var last: [MenuItemModel] = []
        // P2-27: compiled out of Release, so its binary carries no DEBUG lines at all (not just hidden ones).
        #if DEBUG
        if includeDebug { last.append(debugSubmenu(state)) }
        #endif
        last.append(.action("Quit Kytkin", .quit, key: "q"))
        sections.append(last)

        return sections.filter { !$0.isEmpty }.enumerated().flatMap { i, section in
            i == 0 ? section : [.separator] + section
        }
    }

    #if DEBUG
    /// P6-0f: every DEBUG line in one "Debug ▸" submenu (P2-14 / P2-17 checklist tools). Counts and states, never keys.
    static func debugSubmenu(_ state: MenuState) -> MenuItemModel {
        var lines: [MenuItemModel] = [
            .info("Keyboard: \(state.tapMode)\(state.degradedByWatchdog ? " (lowered)" : "")"),
            .info("Double-Shift count: \(state.doubleShiftCount)"),
            .info("Tap re-enables: \(state.tapReEnableCount)"),
            // P2-27 (001 §7 B1): tap callbacks over 1 ms, the on-device check of the callback budget.
            .info("Slow key callbacks (over 1 ms): \(state.slowCallbackCount)"),
        ]
        // P2-55: the learner's gate, candidate and last decision (IDs and reasons only).
        if let line = state.learnerDebug { lines.append(.info(line)) }
        // P3-14: the browser watch (001 §14.12 "Site reads" line; states and counts only, never a host).
        if let line = state.siteDebug { lines.append(.info(line)) }
        lines.append(MenuItemModel(kind: .debugSwitchSubmenu, title: "Switch to", isEnabled: true,
                                   isChecked: false, indent: 0, keyEquivalent: ""))
        return MenuItemModel(kind: .submenu(lines), title: "Debug", isEnabled: true, isChecked: false, indent: 0,
                             keyEquivalent: "")
    }
    #endif

    // MARK: - Context: Always use, Follow My Last Switch, Double-Shift, Forget

    /// P6-0c / P6-0g: the block about the app (or website) in front, as one list (tests and stand-ins).
    static func contextItems(state: MenuState, currentSource: InputSourceInfo?,
                             sourceName: (InputSourceID) -> String,
                             sourceCode: (InputSourceID) -> String? = { _ in nil },
                             appName: (String) -> String) -> [MenuItemModel] {
        contextSections(state: state, currentSource: currentSource, sourceName: sourceName, sourceCode: sourceCode,
                        appName: appName).filter { !$0.isEmpty }.enumerated().flatMap { i, section in
            i == 0 ? section : [.separator] + section
        }
    }

    /// P6-0g: two sections: the language ("In <App>", "Always use" [EN | HE], "Follow My Last Switch"), then
    /// "Turn Off Double-Shift in <App>" and "Forget Rule for <App>". Empty with no app yet (copy review M-3).
    static func contextSections(state: MenuState, currentSource: InputSourceInfo?,
                                sourceName: (InputSourceID) -> String,
                                sourceCode: (InputSourceID) -> String? = { _ in nil },
                                appName: (String) -> String) -> [[MenuItemModel]] {
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

        // P6-0g (review P1): "In cmux" / "On ynet.co.il"; the key and the menu-bar letters say the language.
        var head = (isSite ? "On " : "In ") + here
        if isSite, c.isPrivateWindow == true { head += " (private)" }

        // The pin of exactly this scope. P3-9: compare normalized scopes, so an old hand-edited Unicode key still
        // reads as "this pin".
        let pin = resolution.matched.flatMap {
            $0.origin == .pinned && RuleEngine.normalized($0.scope) == RuleEngine.normalized(rule.pinScope) ? $0 : nil
        }

        var language: [MenuItemModel] = [.header(head)]
        if let pair = state.pairInputSources, !pair.a.rawValue.isEmpty, !pair.b.rawValue.isEmpty, pair.a != pair.b {
            // P6-0g (review P2): both languages can be chosen, not only the current one.
            func half(_ id: InputSourceID) -> MenuItemModel.LanguageKey.Half {
                let name = sourceName(id)
                let code = sourceCode(id) ?? String(name.prefix(2)).uppercased()
                return .init(letters: code, name: name, source: id)
            }
            let chosen: PairSide? = pin.flatMap {
                $0.inputSource == pair.a ? .a : $0.inputSource == pair.b ? .b : nil
            }
            language.append(.languageKey("Always use", MenuItemModel.LanguageKey(a: half(pair.a), b: half(pair.b),
                                                                                  chosen: chosen)))
            if let pin, chosen == nil {
                // Pinned (by hand in the file, or before the pair changed) to a language outside the pair.
                language.append(.info("Always \(sourceName(pin.inputSource))"))
            }
        } else if let current = currentSource {
            // No pair known: pin what is selected now.
            let done = pin?.inputSource == current.id
            language.append(.action("Always Use \(LanguageNames.friendly(current))", done ? .unpinCurrent : .pinCurrent,
                                    checked: done))
        }
        language.append(.action("Follow My Last Switch", .unpinCurrent, checked: pin == nil))

        // P6-0c (flows S3; owner: double-Shift only): the per-app convert switch (Rules' Double-Shift column).
        var app: [MenuItemModel] = [.action("Turn Off Double-Shift in \(appTitle)", .toggleConvertInCurrentApp,
                                            checked: state.convertOffInCurrentApp)]
        // P6-0f: only when there is a rule to forget.
        if let scope = rule.forgetScope {
            app.append(.action("Forget Rule for \(isSite ? here : scopeName(scope, appName: appName))", .forgetCurrent))
        }
        return [language, app]
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
            return open(toggleStillWorks ? "Double-Shift can’t convert: Accessibility is off"
                                         : "Double-Shift and website rules are off: Accessibility is off",
                        .permissions, "Allow Accessibility…")
        case .otherSwitchers(let names):
            // Owner 2026-11-17: a warning only; Settings explains.
            return open("\(joined(names)) also switch\(names.count == 1 ? "es" : "") languages", .general,
                        names.count == 1 ? "Quit it so the two don’t undo each other" : "Quit them so they don’t undo Kytkin")
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
            return open(newerVersion ? "Settings are from a newer Kytkin" : "Settings couldn’t be read",
                        .general, newerVersion ? "Update Kytkin to change them" : "Kytkin is using the defaults")
        case .saveFailed:
            return .info("Settings couldn’t be saved. Changes last until you quit.", symbol: warn)
        case .settingsPartlyReset(let original):
            guard let original else { return .info("Some settings couldn’t be read and were reset", symbol: warn) }
            return .action("Some settings couldn’t be read and were reset", .revealFile(original), symbol: warn,
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
