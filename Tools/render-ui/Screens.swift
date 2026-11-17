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
                                           sources: { Sample.enabledSources }, currentLanguage: { Sample.hebrewInfo })
        let languages = LanguagesSettingsModel(store: store, imported: imported, catalog: catalog,
                                               fileSystem: layoutFS, inputMethods: { Sample.enabledSources })
        let rules = RulesSettingsModel(store: store, appName: Sample.appName, sources: { Sample.allSources },
                                       now: { Sample.date(17, 12, 0) }, extractor: extractor)
        let apps = AppsSettingsModel(store: store, appName: Sample.appName, runningApps: { Sample.running },
                                     ownBundleID: "io.github.kytkin.Kytkin")
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
        let about = AboutInfo(infoDictionary: ["CFBundleDisplayName": "Kytkin", "CFBundleShortVersionString": "0.0.1",
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

    private func panes(_ w: World, tab: SettingsTab, advanced: AdvancedSection = .apps) -> SettingsPanes {
        SettingsPanes(selection: SettingsSelection(tab: tab, advancedSection: advanced), general: w.general,
                      about: w.about, rules: w.rules, convert: w.convert, apps: w.apps, permissions: w.permissionsTab,
                      browsers: w.browsers, openSettingsFolder: {}, showWelcome: {}, select: { _ in })
    }

    /// P6-0c: the window's toolbar tabs can't be drawn offscreen (they are window chrome), so a stand-in of the same
    /// icons and titles sits above the real tab pane (MenuMock.swift).
    private func settingsView(_ w: World, tab: SettingsTab, advanced: AdvancedSection = .apps) -> some View {
        VStack(spacing: 0) {
            ToolbarTabsMock(selected: tab)
            SettingsView(panes: panes(w, tab: tab, advanced: advanced))
                .environment(w.languages)
        }
    }

    private func settingsSize(height: CGFloat? = nil) -> CGSize {
        CGSize(width: SettingsView.size.width, height: (height ?? SettingsView.size.height) + ToolbarTabsMock.height)
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
        let w = try world(support: [SampleIDs.safari: .works, SampleIDs.chrome: .worksWithAutomation,
                                    SampleIDs.zen: .notSeenYet])
        let size = settingsSize()
        for tab in SettingsTab.allCases {
            try r.render("settings-\(tab.rawValue)", size: size, inWindow: tab == .rules) { settingsView(w, tab: tab) }
        }
        for section in AdvancedSection.allCases where section != .apps {
            try r.render("settings-advanced-\(section.rawValue)", size: size) {
                settingsView(w, tab: .advanced, advanced: section)
            }
        }

        // The tabs whose grouped Form scrolls in the window, drawn tall so nothing is cut off.
        let tall: [(SettingsTab, CGFloat)] = [(.general, 760), (.doubleShift, 640), (.websites, 820)]
        for (tab, height) in tall {
            try r.render("settings-\(tab.rawValue)-full", size: settingsSize(height: height)) {
                VStack(spacing: 0) {
                    ToolbarTabsMock(selected: tab)
                    SettingsTabPane(tab: tab, panes: panes(w, tab: tab), height: height).environment(w.languages)
                }
            }
        }
        try r.render("settings-advanced-apps-full", size: settingsSize(height: 900)) {
            VStack(spacing: 0) {
                ToolbarTabsMock(selected: .advanced)
                SettingsTabPane(tab: .advanced, panes: panes(w, tab: .advanced), height: 900).environment(w.languages)
            }
        }

        // Websites with Automation on, Chrome chosen and allowed.
        var auto = Sample.preferences()
        auto.browsers.useAutomation = true
        let wa = try world(prefs: auto, support: [SampleIDs.chrome: .worksWithAutomation],
                           automation: [SampleIDs.chrome: .granted])
        wa.browsers.selectedBrowserID = SampleIDs.chrome
        try r.render("settings-websites-chrome-automation", size: size) { settingsView(wa, tab: .websites) }
        // Zen (Firefox-based, no Automation), not checked yet.
        w.browsers.selectedBrowserID = SampleIDs.zen
        try r.render("settings-websites-zen", size: size) { settingsView(w, tab: .websites) }

        // Setup needs attention: Accessibility off, Secure Input on, conflicts.
        let wt = try world(state: Self.troubledState)
        try r.render("settings-general-setup-missing", size: settingsSize(height: 900)) {
            VStack(spacing: 0) {
                ToolbarTabsMock(selected: .general)
                SettingsTabPane(tab: .general, panes: panes(wt, tab: .general), height: 900).environment(wt.languages)
            }
        }
        try r.render("settings-advanced-diagnostics-troubled", size: size) {
            settingsView(wt, tab: .advanced, advanced: .diagnostics)
        }

        // Read-only preferences (a file from a newer Kytkin): the notice and disabled controls.
        let wr = try world(readOnly: true)
        try r.render("settings-general-readonly", size: size) { settingsView(wr, tab: .general) }
        try r.render("settings-rules-readonly", size: size, inWindow: true) { settingsView(wr, tab: .rules) }

        // Empty states: no rules, no app settings, no imported layouts.
        var empty = Preferences()
        empty.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew)
        let we = try world(prefs: empty)
        try r.render("settings-rules-empty", size: size, inWindow: true) { settingsView(we, tab: .rules) }
        try r.render("settings-advanced-apps-empty", size: size) { settingsView(we, tab: .advanced) }

        // A pair warning: the second language is on this Mac but not added.
        var badPair = Sample.preferences()
        badPair.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrewQWERTY)
        let wb = try world(prefs: badPair)
        try r.render("settings-general-pair-warning", size: settingsSize(height: 760)) {
            VStack(spacing: 0) {
                ToolbarTabsMock(selected: .general)
                SettingsTabPane(tab: .general, panes: panes(wb, tab: .general), height: 760).environment(wb.languages)
            }
        }
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
                            languages: w.languages, appName: "Kytkin", bundlePath: bundlePath,
                            layouts: { snapshot }, sourceName: { $0 == SampleIDs.hebrew ? "Hebrew" : "English" })
        }
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
        try shot("onboarding-3-practice", m)
        m.practiceText = "akuo"
        m.practiceFocused = true
        _ = m.practiceDoubleShift()
        try shot("onboarding-3-practice-converted", m)
        m.finish()

        let moving = model(bundlePath: "/Volumes/Kytkin/Kytkin.app")
        moving.begin(firstLaunch: true)
        try shot("onboarding-0-move-to-applications", moving)
    }

    // MARK: - Menu-bar menu and label (SwiftUI stand-ins, MenuMock.swift)

    private func menuItems(_ state: MenuState, current: InputSourceInfo) -> [MenuItemModel] {
        let names: [InputSourceID: String] = [SampleIDs.abc: "ABC", SampleIDs.hebrew: "Hebrew"]
        return MenuModel.items(state: state, currentSource: current, version: "0.0.1", settingsAvailable: true,
                               includeDebug: false, sourceName: { names[$0] ?? $0.rawValue },
                               appName: { Sample.appName($0) ?? $0 })
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
