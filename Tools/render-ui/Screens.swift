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
                                           sources: { Sample.enabledSources })
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

    private func settingsView(_ w: World, tab: SettingsTab) -> some View {
        SettingsView(selection: SettingsSelection(tab: tab), general: w.general, about: w.about, rules: w.rules,
                     convert: w.convert, apps: w.apps, permissions: w.permissionsTab, browsers: w.browsers,
                     openSettingsFolder: {}, showWelcome: {}, tabChanged: {})
            .environment(w.languages)
            .overlay(alignment: .top) {   // the tab buttons NSTabView can't draw offscreen (MenuMock.swift)
                TabStripOverlay(selected: tab).padding(.horizontal, 26).padding(.top, 18)
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
        let w = try world(support: [SampleIDs.safari: .works, SampleIDs.chrome: .worksWithAutomation,
                                    SampleIDs.zen: .notSeenYet])
        let size = SettingsView.size
        for tab in SettingsTab.allCases {
            try r.render("settings-\(tab.rawValue)", size: size, inWindow: tab == .rules) { settingsView(w, tab: tab) }
        }

        // The tabs whose grouped Form scrolls in the 680×500 window, drawn tall so nothing is cut off.
        let tall: [(SettingsTab, CGFloat)] = [(.languages, 490), (.rules, 600), (.convert, 660), (.apps, 1020),
                                              (.browsers, 800)]
        for (tab, height) in tall {
            try r.render("settings-\(tab.rawValue)-full", size: CGSize(width: size.width, height: height),
                         inWindow: tab == .rules) {
                tabContent(w, tab: tab).padding(20)
            }
        }

        // Browsers & Sites with Automation on, Chrome chosen and allowed.
        var auto = Sample.preferences()
        auto.browsers.useAutomation = true
        let wa = try world(prefs: auto, support: [SampleIDs.chrome: .worksWithAutomation],
                           automation: [SampleIDs.chrome: .granted])
        wa.browsers.selectedBrowserID = SampleIDs.chrome
        try r.render("settings-browsers-chrome-automation", size: size) { settingsView(wa, tab: .browsers) }
        // Zen (Firefox-based, no Automation), not checked yet.
        w.browsers.selectedBrowserID = SampleIDs.zen
        try r.render("settings-browsers-zen", size: size) { settingsView(w, tab: .browsers) }

        // Permissions missing: Accessibility off, Secure Input on, conflicts.
        let wt = try world(state: Self.troubledState)
        try r.render("settings-permissions-missing", size: size) { settingsView(wt, tab: .permissions) }
        try r.render("settings-permissions-missing-full", size: CGSize(width: size.width, height: 740)) {
            tabContent(wt, tab: .permissions).padding(20)
        }

        // Read-only preferences (a file from a newer Kytkin): the notice banners and disabled controls.
        let wr = try world(readOnly: true)
        try r.render("settings-general-readonly", size: size) { settingsView(wr, tab: .general) }
        try r.render("settings-rules-readonly", size: size, inWindow: true) { settingsView(wr, tab: .rules) }

        // Empty states: no rules, no app settings, no imported layouts.
        var empty = Preferences()
        empty.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrew)
        let we = try world(prefs: empty)
        try r.render("settings-rules-empty", size: size, inWindow: true) { settingsView(we, tab: .rules) }
        try r.render("settings-apps-empty", size: size) { settingsView(we, tab: .apps) }

        // A pair warning: Language B is installed but not turned on.
        var badPair = Sample.preferences()
        badPair.languagePair = LanguagePair(a: SampleIDs.abc, b: SampleIDs.hebrewQWERTY)
        let wb = try world(prefs: badPair)
        try r.render("settings-languages-warning", size: size) { settingsView(wb, tab: .languages) }
    }

    @ViewBuilder private func tabContent(_ w: World, tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(model: w.general, showWelcome: {})
        case .languages: LanguagesSettingsView().environment(w.languages)
        case .rules: RulesSettingsView(model: w.rules)
        case .convert: ConvertSettingsView(model: w.convert)
        case .apps: AppsSettingsView(model: w.apps)
        case .browsers: BrowsersSettingsView(model: w.browsers, openPermissions: {}, showWebsiteRules: {})
        case .permissions: PermissionsSettingsView(model: w.permissionsTab)
        case .about: AboutSettingsView(info: w.about, openSettingsFolder: {})
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
        let model = OnboardingModel(store: w.store, permissions: w.permissions, polling: w.polling, general: w.general,
                                    languages: w.languages, appName: "Kytkin")
        model.begin(firstLaunch: false)
        let size = OnboardingView.size
        func shot(_ name: String) throws {
            try r.render(name, size: size) { OnboardingView(model: model, close: {}) }
        }
        try shot("onboarding-1-welcome")
        model.next()
        try shot("onboarding-2-languages")
        model.next()
        try shot("onboarding-3-accessibility")
        model.grantAccessibility()   // the fake records nothing and asks nothing: the step shows "Waiting for you…"
        try shot("onboarding-3-accessibility-waiting")
        w.permissions.status.grants.accessibility = .granted
        model.reload()
        try shot("onboarding-3-accessibility-granted")
        model.next()
        try shot("onboarding-4-finish")
        model.finish()
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

        let ok = Self.healthyState
        let samples: [StatusLabelMock.Sample] = [
            .init(caption: "English (ABC) selected", label: MenuModel.label(languageCode: "en", state: ok)),
            .init(caption: "Hebrew selected", label: MenuModel.label(languageCode: "he", state: ok)),
            .init(caption: "Hebrew, a warning applies (dot)", label: MenuModel.label(languageCode: "he", state: warn)),
            .init(caption: "Paused (dot, dimmed)", label: MenuModel.label(languageCode: "en", state: paused)),
            .init(caption: "Unknown input source", label: MenuModel.label(languageCode: nil, state: ok)),
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
