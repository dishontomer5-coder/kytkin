// P6-0a: Every screen the renderer draws, built from the app's own Core models over fakes (the same models
// AppEnvironment builds over live adapters). The file names here are listed in docs/design/p6-0-snapshots/README.md.

import AppKit
import SwiftUI

@MainActor struct Screens {
    let repoRoot: URL

    private let base = URL(fileURLWithPath: "/nonexistent/kytkin-render-ui", isDirectory: true)
    private var prefsURL: URL { base.appendingPathComponent("preferences.json") }
    private var layoutsDir: URL { base.appendingPathComponent("layouts", isDirectory: true) }

    // MARK: - The pretend Mac

    private func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("Tests/KytkinTests/Fixtures/\(path)"))
    }

    private func layouts() throws -> FixtureLayouts {
        let l = FixtureLayouts()
        for (id, file) in [(SampleIDs.abc, "ABC"), (SampleIDs.hebrew, "Hebrew"),
                           (SampleIDs.hebrewQWERTY, "Hebrew-QWERTY")] {
            l.maps[id] = try JSONDecoder().decode(
                LayoutMap.self, from: fixture("layoutmaps/com.apple.keylayout.\(file).json"))
        }
        l.infos = [Sample.abcInfo, Sample.hebrewInfo, Sample.hebrewQWERTYInfo]
        return l
    }

    private func suffixListText() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("Resources/PublicSuffixList/public_suffix_list.dat"),
                   encoding: .utf8)
    }

    private func store(_ prefs: Preferences, readOnly: Bool = false) throws -> PreferencesStore {
        let data = try PreferencesCodec.encode(
            prefs, schemaVersion: Preferences.currentSchemaVersion + (readOnly ? 1 : 0))
        return PreferencesStore(fileURL: prefsURL, clock: FrozenClock(), fileSystem: MemoryPreferencesFS(files: [prefsURL: data]))
    }

    /// Every Settings model over one store, as SettingsWindowController gets them.
    struct World {
        let store: PreferencesStore
        let permissions: FakePermissions
        let general: GeneralSettingsModel
        let languages: LanguagesSettingsModel
        let rules: RulesSettingsModel
        let convert: ConvertSettingsModel
        let apps: AppsSettingsModel
        let permissionsTab: PermissionsSettingsModel
        let browsers: BrowsersSettingsModel
        let about: AboutInfo
        let polling: PermissionPollingDemand
    }

    private func world(prefs: Preferences = Sample.preferences(), readOnly: Bool = false,
                       state: MenuState = Self.healthyState, support: [String: BrowserSupport] = [:],
                       automation: [String: PermissionState] = [:]) throws -> World {
        let store = try store(prefs, readOnly: readOnly)
        let permissions = FakePermissions()
        permissions.status = PermissionStatus(grants: PermissionGrants(
            accessibility: state.accessibility, inputMonitoring: state.inputMonitoring, automation: automation))
        let polling = PermissionPollingDemand(permissions: permissions)
        let layoutFS = MemoryLayoutFS(files: [
            layoutsDir.appendingPathComponent("user.he-custom.json"): try fixture("layoutmaps/sample-user.json"),
        ])
        let imported = ImportedLayoutStore(directory: layoutsDir, fileSystem: layoutFS)
        let catalog = LayoutMapCatalog(system: try layouts(), imported: imported)
        let suffixText = try suffixListText()
        let extractor = DomainExtractor(suffixList: PublicSuffixList(datContents: suffixText))

        let general = GeneralSettingsModel(store: store, loginItems: FakeLoginItems(),
                                           sources: { Sample.enabledSources }, currentLanguage: { Sample.current },
                                           updates: UpdateChecker(store: store, http: NoNetwork(), appVersion: "1.0.0"))
        let languages = LanguagesSettingsModel(store: store, imported: imported, catalog: catalog,
                                               fileSystem: layoutFS, inputMethods: { Sample.enabledSources })
        let apps = AppsSettingsModel(store: store, appName: Sample.appName, runningApps: { Sample.running },
                                     ownBundleID: "io.github.kytkin.Kytkin")
        let rules = RulesSettingsModel(store: store, appName: Sample.appName, sources: { Sample.allSources },
                                       now: { Sample.date(17, 12, 0) }, extractor: extractor, apps: apps)
        let permissionsTab = PermissionsSettingsModel(permissions: permissions, store: store, polling: polling,
                                                      appName: "Kytkin", state: { state }, relaunch: {})
        let automationController = BrowserAutomationController(store: store, permissions: permissions,
                                                               isRunning: { _ in true })
        let browsers = BrowsersSettingsModel(
            store: store, appName: Sample.appName, suffixListLoaded: true, ownBundleIDPrefix: "io.github.kytkin",
            inventory: { BrowserInventorySnapshot(installedCatalog: [SampleIDs.safari, SampleIDs.chrome, SampleIDs.zen],
                                                  webLinkHandlers: [SampleIDs.safari, SampleIDs.chrome, SampleIDs.zen]) },
            support: { support[$0] ?? .notSeenYet },
            automation: automationController,
            lastFrontBrowser: { SampleIDs.safari })
        let about = AboutInfo(infoDictionary: ["CFBundleDisplayName": "Kytkin Dev", "CFBundleShortVersionString": "1.0.0",
                                               "CFBundleVersion": "1"],
                              suffixListVersion: PublicSuffixList.version(inHeader: suffixText.prefix(4096)))
        general.refresh()
        languages.refresh()
        rules.refresh()
        apps.refresh()
        permissionsTab.reload()
        browsers.refresh()
        return World(store: store, permissions: permissions, general: general, languages: languages, rules: rules,
                     convert: ConvertSettingsModel(store: store), apps: apps, permissionsTab: permissionsTab,
                     browsers: browsers, about: about, polling: polling)
    }

    static let healthyState: MenuState = {
        var s = MenuState()
        s.accessibility = .granted
        s.inputMonitoring = .granted
        s.tapMode = .active
        return s
    }()

    static let troubledState: MenuState = {
        var s = MenuState()
        s.accessibility = .denied
        s.inputMonitoring = .notDetermined
        s.tapMode = .off
        s.secureInputOn = true
        s.conflicts = Conflicts(runningSwitchers: ["Input Source Pro"], perDocumentInputEnabled: true)
        return s
    }()

    /// P6-0g: the heights the panes report (the window sizes itself to them).
    final class Heights {
        var natural: [SettingsTab: CGFloat] = [:]
    }

    private func panes(_ w: World, tab: SettingsTab, heights: Heights? = nil) -> SettingsPanes {
        SettingsPanes(selection: SettingsSelection(tab: tab), general: w.general,
                      about: w.about, rules: w.rules, convert: w.convert, permissions: w.permissionsTab,
                      browsers: w.browsers, openSettingsFolder: {}, showWelcome: {}, select: { _ in },
                      reportHeight: { tab, h in heights?.natural[tab] = max(heights?.natural[tab] ?? 0, h) })
    }

    /// P6-0c: the window's toolbar tabs can't be drawn offscreen (they are window chrome), so a stand-in of the same
    /// icons and titles sits above the real tab pane (MenuMock.swift).
    private func settingsView(_ w: World, tab: SettingsTab, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            ToolbarTabsMock(selected: tab)
            SettingsView(panes: panes(w, tab: tab), height: height)
                .environment(w.languages)
        }
    }

    private func settingsSize(height: CGFloat) -> CGSize {
        CGSize(width: SettingsMetrics.width, height: height + ToolbarTabsMock.height)
    }

    /// P6-0g: the tab's natural content height, measured as the window measures it (one drawing, not saved).
    private func naturalHeight(_ w: World, tab: SettingsTab, _ r: Renderer) throws -> CGFloat {
        let heights = Heights()
        let p = panes(w, tab: tab, heights: heights)
        try r.render("measure", size: CGSize(width: SettingsMetrics.width, height: 1600), inWindow: tab == .rules,
                     write: false) {
            SettingsTabPane(tab: tab, panes: p, height: 1600).environment(w.languages)
        }
        return heights.natural[tab] ?? SettingsMetrics.minHeight
    }

    /// One Settings shot at the window's size for that tab (380–640 pt); with `full`, at the content's own height too
    /// when it scrolls in the window.
    private func shot(_ name: String, _ w: World, tab: SettingsTab, _ r: Renderer, full: Bool = false) throws {
        let natural = try naturalHeight(w, tab: tab, r)
        let height = SettingsMetrics.height(for: natural)
        try r.render(name, size: settingsSize(height: height), inWindow: tab == .rules) {
            settingsView(w, tab: tab, height: height)
        }
        if full, natural > SettingsMetrics.maxHeight {
            try r.render(name + "-full", size: settingsSize(height: ceil(natural)), inWindow: tab == .rules) {
                settingsView(w, tab: tab, height: ceil(natural))
            }
        }
    }

    // MARK: - Render everything

    func renderAll(with r: Renderer) throws {
        // The first Form drawn in the process comes out soft (1x text); draw one and throw it away.
        try r.render("warm-up", size: CGSize(width: 400, height: 250), write: false) { WarmUpView() }
        try renderSettings(r)
        try renderSheets(r)
        try renderOnboarding(r)
        try renderMenu(r)
    }

    private func renderSettings(_ r: Renderer) throws {
        let w = try world(support: [SampleIDs.safari: .works, SampleIDs.chrome: .cantRead,
                                    SampleIDs.zen: .notSeenYet])
        for tab in SettingsTab.allCases {
            try shot("settings-\(tab.rawValue)", w, tab: tab, r, full: true)
        }

        // Websites with Automation on and Chrome allowed.
        var auto = Sample.preferences()
        auto.browsers.useAutomation = true
        let wa = try world(prefs: auto, support: [SampleIDs.safari: .works, SampleIDs.chrome: .worksWithAutomation,
                                                  SampleIDs.zen: .cantRead],
                           automation: [SampleIDs.chrome: .granted])
        try shot("settings-websites-automation", wa, tab: .websites, r)
        // Website rules off: everything under the switch dimmed.
        var off = Sample.preferences()
        off.browsers.siteRulesOn = false
        let wo = try world(prefs: off)
        try shot("settings-websites-off", wo, tab: .websites, r)

        // Setup needs attention: Accessibility off, Secure Input on, conflicts.
        let wt = try world(state: Self.troubledState)
        try shot("settings-general-setup-missing", wt, tab: .general, r, full: true)
        try shot("settings-advanced-troubled", wt, tab: .advanced, r)

        // Read-only preferences (a file from a newer Kytkin): the notice and disabled controls.
        let wr = try world(readOnly: true)
        try shot("settings-general-readonly", wr, tab: .general, r)
        try shot("settings-rules-readonly", wr, tab: .rules, r)

        // Empty states: no rules, no imported layouts.
        var empty = Preferences()
        empty.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew)
        let we = try world(prefs: empty)
        try shot("settings-rules-empty", we, tab: .rules, r)

        // A pair warning: the second language is on this Mac but not added.
        var badPair = Sample.preferences()
        badPair.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrewQWERTY)
        let wb = try world(prefs: badPair)
        try shot("settings-general-pair-warning", wb, tab: .general, r, full: true)
    }

    private func renderSheets(_ r: Renderer) throws {
        let w = try world()
        w.rules.beginAddWebsite()
        if let form = w.rules.addWebsite {
            try r.render("sheet-add-website-empty") { sheet(form) }
            form.text = "https://www.haaretz.co.il/news/politics"
            try r.render("sheet-add-website-choice") { sheet(form) }
            form.text = "ynet.co.il"
            try r.render("sheet-add-website-replaces") { sheet(form) }
            form.text = "not a website"
            try r.render("sheet-add-website-invalid") { sheet(form) }
        }
        w.rules.beginAddWebsite(subdomainOf: "ynet.co.il")
        if let form = w.rules.addWebsite {
            try r.render("sheet-add-subdomain") { sheet(form) }
            form.text = "news.ynet.co.il"
            try r.render("sheet-add-subdomain-filled") { sheet(form) }
        }
    }

    private func sheet(_ form: AddWebsiteForm) -> some View {
        AddWebsiteSheet(form: form, save: {}, cancel: {})
    }

    private func renderOnboarding(_ r: Renderer) throws {
        var prefs = Sample.preferences()
        prefs.general.onboardingSeen = false
        var state = MenuState()
        state.accessibility = .notDetermined
        let w = try world(prefs: prefs, state: state)
        let maps = try layouts().maps
        let snapshot = maps[SampleIDs.abc].flatMap { a in maps[SampleIDs.hebrew].flatMap { b in
            LayoutSnapshot(pair: LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew), a: a, b: b)
        } }
        func model(bundlePath: String = "/Applications/Kytkin.app") -> OnboardingModel {
            OnboardingModel(store: w.store, permissions: w.permissions, polling: w.polling, general: w.general,
                            languages: w.languages, appName: "Kytkin", bundlePath: bundlePath, updates: w.general.updates,
                            layouts: { snapshot }, sourceName: { $0 == SampleIDs.hebrew ? "Hebrew" : "English" },
                            // QA (P6-0i): the pretend keyboard really switches, so the chip shows EN while typing.
                            selectSource: { Sample.select($0) })
        }
        defer { Sample.current = Sample.hebrewInfo }
        let m = model()
        m.begin(firstLaunch: true)
        let size = OnboardingView.size
        func shot(_ name: String, _ m: OnboardingModel) throws {
            try r.render(name, size: size) { OnboardingView(model: m, close: {}) }
        }
        try shot("onboarding-1-welcome", m)
        m.next()
        try shot("onboarding-2-permissions", m)
        m.grantAccessibility()   // the fake records nothing and asks nothing: the step shows "Waiting…"
        try shot("onboarding-2-permissions-waiting", m)
        w.permissions.status.grants.accessibility = .granted
        m.reload()
        try shot("onboarding-2-permissions-granted", m)
        m.next()
        // P6-0i: the ghost word: empty, half typed, a wrong key, every letter (one Shift lit), converted, confetti.
        try shot("onboarding-3-practice", m)
        m.practiceText = "ak"
        m.practiceTextChanged()
        try shot("onboarding-3-practice-half", m)
        m.practiceText = "akx"
        m.practiceTextChanged()
        try shot("onboarding-3-practice-wrong-key", m)
        m.practiceText = "akuo"
        m.practiceTextChanged()
        m.noteShiftPressed()
        OnboardingView.renderCelebrationAt = 0
        try shot("onboarding-3-practice-wrong-language", m)
        m.practiceFocused = true
        if let target = m.practiceDoubleShift() { Sample.select(target) }   // the after-convert switch
        m.reload()
        OnboardingView.renderCelebrationAt = 0.35
        try shot("onboarding-3-practice-confetti", m)
        OnboardingView.renderCelebrationAt = nil
        try shot("onboarding-3-practice-converted", m)
        m.finish()

        let moving = model(bundlePath: "/Volumes/Kytkin/Kytkin.app")
        moving.begin(firstLaunch: true)
        try shot("onboarding-0-move-to-applications", moving)
    }

    // MARK: - Menu-bar menu and label (SwiftUI stand-ins, MenuMock.swift)

    private func menuItems(_ state: MenuState, current: InputSourceInfo) -> [MenuItemModel] {
        // P6-0g: the menu says "English", not "ABC"; the key shows the pair's letters.
        let names: [InputSourceID: String] = [SampleIDs.abc: "English", SampleIDs.hebrew: "Hebrew"]
        let codes: [InputSourceID: String] = [SampleIDs.abc: "EN", SampleIDs.hebrew: "HE"]
        var state = state
        if state.pairInputSources == nil { state.pairInputSources = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew) }
        return MenuModel.items(state: state, currentSource: current, settingsAvailable: true,
                               includeDebug: false, sourceName: { names[$0] ?? $0.rawValue },
                               sourceCode: { codes[$0] }, appName: { Sample.appName($0) ?? $0 })
    }

    private func current(_ c: Context, rules: [Rule] = Sample.rules) -> SwitchController.CurrentRule {
        let engine = RuleEngine(rules: rules)
        return SwitchController.CurrentRule(context: c, resolution: engine.resolve(c), pinScope: engine.pinScope(for: c))
    }

    private func renderMenu(_ r: Renderer) throws {
        let desk = NSColor.underPageBackgroundColor
        var s = Self.healthyState

        s.currentRule = current(Context(bundleID: SampleIDs.notes, pid: 101, generation: 1))
        let notes = menuItems(s, current: Sample.hebrewInfo)
        try r.render("menu-app-learned", backdrop: desk) { MenuMock(items: notes) }

        s.currentRule = current(Context(bundleID: SampleIDs.whatsapp, pid: 102, generation: 2))
        let pinned = menuItems(s, current: Sample.hebrewInfo)
        try r.render("menu-app-pinned", backdrop: desk) { MenuMock(items: pinned) }

        s.currentRule = current(Context(bundleID: SampleIDs.safari, pid: 103, host: "www.ynet.co.il",
                                        siteDomain: "ynet.co.il", pageState: .page, generation: 3))
        let site = menuItems(s, current: Sample.hebrewInfo)
        try r.render("menu-site", backdrop: desk) { MenuMock(items: site) }

        s.currentRule = current(Context(bundleID: SampleIDs.chrome, pid: 104, host: "github.com",
                                        siteDomain: "github.com", isPrivateWindow: false, pageState: .page,
                                        generation: 4))
        let github = menuItems(s, current: Sample.abcInfo)
        try r.render("menu-site-learned", backdrop: desk) { MenuMock(items: github) }

        s.currentRule = current(Context(bundleID: SampleIDs.mail, pid: 105, generation: 5))
        let noRule = menuItems(s, current: Sample.abcInfo)
        try r.render("menu-no-rule", backdrop: desk) { MenuMock(items: noRule) }

        var paused = Self.healthyState
        paused.paused = true
        paused.currentRule = current(Context(bundleID: SampleIDs.notes, pid: 101, generation: 1))
        let pausedItems = menuItems(paused, current: Sample.hebrewInfo)
        try r.render("menu-paused", backdrop: desk) { MenuMock(items: pausedItems) }

        var warn = Self.troubledState
        warn.showsQuitAndReopen = true
        warn.currentRule = current(Context(bundleID: SampleIDs.notes, pid: 101, generation: 1))
        let warnItems = menuItems(warn, current: Sample.hebrewInfo)
        try r.render("menu-warnings", backdrop: desk) { MenuMock(items: warnItems) }

        var store = Self.healthyState
        store.enabled = false
        store.store.isReadOnly = true
        store.store.loadIssue = nil
        store.currentRule = nil
        let storeItems = menuItems(store, current: Sample.abcInfo)
        try r.render("menu-off-no-app", backdrop: desk) { MenuMock(items: storeItems) }

        // P6-0e: the pair, so the logo fills the half of the language that is on (-a English, -b Hebrew).
        let pair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew)
        var ok = Self.healthyState
        ok.pairInputSources = pair
        var off = ok
        off.enabled = false
        var warnP = warn
        warnP.pairInputSources = pair
        var pausedP = paused
        pausedP.pairInputSources = pair
        let en = SampleIDs.abc, he = SampleIDs.hebrew
        let samples: [StatusLabelMock.Sample] = [
            .init(caption: "English (ABC) on: left half", label: MenuModel.label(languageCode: "en", state: ok, current: en)),
            .init(caption: "Hebrew on: right half", label: MenuModel.label(languageCode: "he", state: ok, current: he)),
            .init(caption: "Hebrew, needs attention",
                  label: MenuModel.label(languageCode: "he", state: warnP, current: he)),
            .init(caption: "Paused (45 % fill)", label: MenuModel.label(languageCode: "en", state: pausedP, current: en)),
            .init(caption: "Turned off (35 %, letters too)",
                  label: MenuModel.label(languageCode: "he", state: off, current: he)),
            .init(caption: "Unknown language (icon only)", label: MenuModel.label(languageCode: nil, state: ok)),
            .init(caption: "Icon only mode",
                  label: MenuModel.label(languageCode: "he", state: ok, display: .iconOnly, current: he)),
            .init(caption: "Language only mode",
                  label: MenuModel.label(languageCode: "he", state: ok, display: .languageOnly, current: he)),
            .init(caption: "Language only, needs attention",
                  label: MenuModel.label(languageCode: "he", state: warnP, display: .languageOnly, current: he)),
        ]
        try r.render("statusitem-labels", backdrop: desk) { StatusLabelMock(samples: samples) }
    }
}

/// A small grouped Form, drawn once before the real screens (see renderAll).
struct WarmUpView: View {
    @State var on = true
    @State var sel = 1
    var body: some View {
        Form {
            Section("Header") {
                Toggle("Kytkin is on", isOn: $on)
                Picker("Pick", selection: $sel) { Text("One").tag(1); Text("Two").tag(2) }
                Text("Caption").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
