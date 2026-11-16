// P2-20: The composition root (001 §2, design.md "Only AppEnvironment knows the concrete types"). It builds every
// live adapter, sets each `on…` callback exactly once (P2-43, 001 §12 W3: one owner per callback) and forwards it to
// one AppController method, which holds every decision and is unit-tested with fakes. Nothing here decides anything.
//
// Never built in tests: it creates the live TIS backend, the real event tap (KeyWatcher+Live), the permission
// requester and the workspace observers.

import AppKit

@MainActor final class AppEnvironment {
    let store: PreferencesStore
    let switcher: InputSourceSwitcher
    let layoutMaps: UCKeyTranslateLayoutMapProvider   // P2-21 (ConvertDispatcher), P2-24 read it
    /// P2-24: the user's imported maps (`…/Kytkin[ Dev]/layouts/`), and system + imported maps together (P2-32).
    let importedLayouts: ImportedLayoutStore
    let layoutCatalog: LayoutMapCatalog
    let contextMonitor: ContextMonitor
    let permissions: PermissionsManager
    /// P3-7: Automation for Settings → Browsers & Sites. P3-26: the global switch plus each browser's permission.
    let automation: BrowserAutomationController
    let conflicts: ConflictDetector
    let keyWatcher: KeyWatcher
    let convert: ConvertDispatcher
    let controller: AppController
    let statusItem: StatusItemController
    /// P2-23: built on first `openSettings`, then reused.
    private var settingsWindow: SettingsWindowController?
    /// P2-26: the welcome window, built on first use (launch, or Settings → General → "Show Welcome Again").
    private var onboardingWindow: OnboardingWindowController?
    /// P2-26: Settings and the welcome window share these (one General / Languages model, one poll switch).
    private lazy var sharedModels = makeSharedModels()
    /// P2-26: the name System Settings lists ("Kytkin Dev" for Debug builds).
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Kytkin"

    private var appObservers: [NSObjectProtocol] = []

    init() {
        let clock = SystemClock()
        let fileURL = (try? PreferencesLocation.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(PreferencesLocation.fileName)
        store = PreferencesStore(fileURL: fileURL, clock: clock)
        switcher = InputSourceSwitcher.makeTIS(clock: clock)
        layoutMaps = UCKeyTranslateLayoutMapProvider()
        importedLayouts = ImportedLayoutStore(directory: ImportedLayoutStore.directory(forPreferencesFile: fileURL),
                                              fileSystem: LocalLayoutFileSystem())
        layoutCatalog = LayoutMapCatalog(system: layoutMaps, imported: importedLayouts)
        // P3-14: the browser watcher exists only when the bundled Public Suffix List loaded (D11: without it no browser
        // is watched, and Settings → Browsers & Sites says so). Its AX thread starts on the first attach.
        let extractor = DomainExtractor.bundled
        contextMonitor = ContextMonitor(source: WorkspaceAppActivationSource(),
                                        browsers: extractor.map { BrowserWatcher.live(extractor: $0) }, clock: clock)
        // P3-7: silent Automation checks; the requester asks only from a click (BrowserAutomationController).
        permissions = PermissionsManager(probe: SystemPermissionProbe(), requester: SystemPermissionRequester(),
                                         clock: clock, automationProbe: SystemAutomationPermission(),
                                         automationRequester: SystemAutomationRequester())
        automation = BrowserAutomationController(store: store, permissions: permissions,
                                                 isRunning: { SystemAutomationPermission.runningPid($0) != nil })
        conflicts = ConflictDetector(clock: clock)

        // KeyWatcher delivers on the main queue; the box lets its closures reach the controller built after it.
        let box = ControllerBox()
        keyWatcher = KeyWatcher(
            processor: KeyStreamProcessor(config: AppController.initialProcessorConfig(store)),
            onSignal: { signal in MainActor.assumeIsolated { box.controller?.keySignal(signal) } },
            onStatus: { status in MainActor.assumeIsolated { box.controller?.keyWatcherStatusDidChange(status) } })

        // P2-21: double-Shift convert on @TextActor (001 §3 (c)). The text replacer is created on first use, on
        // @TextActor (it holds AX elements). The after-convert switch hops back to main, to AppController.
        let convertController = ConvertController(
            keyWatcher: keyWatcher, clock: clock,
            beep: { Task { @MainActor in NSSound.beep() } },
            makeReplacer: { TextReplacer() },
            switchLanguage: { target, keepsBuffer in
                await MainActor.run { box.controller?.switchAfterConvert(to: target, keepsBuffer: keepsBuffer) ?? false }
            },
            // P3-37 (c): the clipboard convert's live seams, made on @TextActor on first use. ConvertController uses it
            // only in unreadable non-terminal apps, with Settings → Convert's clipboard switch on.
            makeClipboard: { [clock] in
                ClipboardConvert(pasteboard: SystemPasteboard(), poster: CGEventKeyPoster(), clock: clock,
                                 sleep: { nanos in try? await Task.sleep(nanoseconds: nanos) })
            },
            // P3-42: the Chromium/Electron AX convert's live seams (AX focus + CGEvent posting), made on @TextActor on
            // first use. Kill switch: the code constant, or `defaults write <bundle id> KytkinDisableChromiumAX -bool YES`.
            makeChromiumAX: { [clock] in
                ChromiumAXConvert(focusProvider: AXFocusedElementProvider(), poster: CGEventKeyPoster(), clock: clock,
                                  sleep: { nanos in try? await Task.sleep(nanoseconds: nanos) })
            },
            chromiumAXEnabled: ChromiumAXConvert.isEnabled
                && !UserDefaults.standard.bool(forKey: ChromiumAXConvert.killSwitchDefaultsKey),
            // P3-44: DEBUG builds only: one privacy-safe line per double-Shift (paths tried, stop reasons; no text).
            diagnose: ConvertDiagnosticsLog.hook)
        convert = ConvertDispatcher(controller: convertController, maps: layoutCatalog)   // P2-32: system, else imported

        controller = AppController(switcher: switcher, context: contextMonitor, store: store,
                                   permissions: permissions, conflicts: conflicts, keyWatcher: keyWatcher,
                                   ticker: MainRunLoopTicker(), convert: convert, clock: clock,
                                   scheduler: MainRunLoopOneShot(),          // P2-52 item 1
                                   frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                                   suffixListLoaded: extractor != nil,                // P3-14 (D11)
                                   webLinkHandlers: { BrowserInventory.webLinkHandlers() },
                                   addressBarLanguage: { [layoutCatalog] pair in       // P3-29: imported maps too
                                       AddressBarLanguage.latinSource(
                                           pair: pair, layouts: layoutCatalog.convertibleLayouts(includeDisabled: true),
                                           inputSource: layoutCatalog.inputSource(for:))
                                   })
        box.controller = controller
        statusItem = StatusItemController(switcher: switcher, menu: controller)
        wire()
    }

    /// The only place any `on…` callback is assigned (P2-43).
    private func wire() {
        let controller = self.controller
        let statusItem = self.statusItem
        switcher.onChange = { change in controller.inputSourceDidChange(change) }
        switcher.onSourcesListChanged = {
            controller.sourcesListDidChange()
            statusItem.sourcesListDidChange()
        }
        contextMonitor.onChange = { context in controller.contextDidChange(context) }
        permissions.onChange = { status in controller.permissionsDidChange(status) }
        conflicts.onChange = { conflicts in controller.conflictsDidChange(conflicts) }
        // P2-26: the root fans the display change out: the menu-bar label, and the Permissions tab / welcome window
        // (so they follow a grant, the P2-46 tap retry and Secure Input without a timer of their own).
        controller.onDisplayChange = { [weak self] in
            statusItem.refresh()
            self?.displayDidChange()
        }
        // P2-22 + P2-23: the menu's "Settings…", "Open Settings…" and About open the Settings window on that tab.
        statusItem.openSettings = { [weak self] target in
            switch target {
            case .general: self?.openSettings(tab: .general)
            case .permissions: self?.openSettings(tab: .permissions)
            case .about: self?.openSettings(tab: .about)
            }
        }

        // P2-39 (001 §12 W2): Kytkin's own windows are not a context.
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // P2-55: opening the status-bar menu can post this while the other app stays frontmost.
                    // The pid comparison is the fact; AppController decides what it means (and looks again in case
                    // frontmost lags behind, e.g. Settings brought forward with NSApp.activate()).
                    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    controller.kytkinDidBecomeActive(isFrontmost: front == ProcessInfo.processInfo.processIdentifier)
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    controller.kytkinDidResignActive(frontmostPID: pid)
                }
            },
        ]
    }

    /// P2-23: the menu's "Settings…" hook (P2-22 calls it). Opens the Settings window on `tab`, or brings the open
    /// one to the front on that tab. User action only.
    func openSettings(tab: SettingsTab = .general) {
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.show(tab: tab)
    }

    /// P2-26: the welcome window. `firstLaunch` = shown by itself at launch; otherwise the user asked for it.
    func openOnboarding(firstLaunch: Bool = false) {
        let window = onboardingWindow ?? OnboardingWindowController(model: OnboardingModel(
            store: store, permissions: permissions, polling: sharedModels.polling, general: sharedModels.general,
            languages: sharedModels.languages, appName: Self.appName))
        onboardingWindow = window
        window.show(firstLaunch: firstLaunch)
    }

    private func displayDidChange() {
        settingsWindow?.permissionsChanged()
        onboardingWindow?.reload()
    }

    private struct SharedModels {
        let polling: PermissionPollingDemand
        let general: GeneralSettingsModel
        let languages: LanguagesSettingsModel
    }

    private func makeSharedModels() -> SharedModels {
        let switcher = self.switcher
        // P2-23: SMAppServiceLoginItems only reads the status here; register/unregister run on the user's toggle.
        let general = GeneralSettingsModel(store: store, loginItems: SMAppServiceLoginItems(),
                                           sources: { switcher.sources(includeDisabled: false) })
        // P2-24: reads the layout lists only on refresh (when Settings opens); files only on the user's clicks.
        let languages = LanguagesSettingsModel(store: store, imported: importedLayouts, catalog: layoutCatalog,
                                               fileSystem: importedLayouts.fileSystem,
                                               inputMethods: { switcher.sources(includeDisabled: false) })
        return SharedModels(polling: PermissionPollingDemand(permissions: permissions), general: general,
                            languages: languages)
    }

    private func makeSettingsWindow() -> SettingsWindowController {
        let general = sharedModels.general
        let languages = sharedModels.languages
        let controller = self.controller
        let switcher = self.switcher
        // P2-26: the Permissions tab reads what AppController knows (grants, tap mode, Secure Input, the P2-46
        // "Quit & Reopen" hint); its buttons are the user's clicks.
        let permissionsTab = PermissionsSettingsModel(permissions: permissions, store: store,
                                                      polling: sharedModels.polling, appName: Self.appName,
                                                      state: { controller.menuState },
                                                      relaunch: { AppRelauncher.quitAndReopen() })
        // P2-25: Rules, Convert and Apps. Names come from LaunchServices; running apps only when Settings opens.
        let rules = RulesSettingsModel(store: store, appName: StatusItemController.lookUpAppName,
                                       sources: { switcher.sources(includeDisabled: true) },
                                       extractor: DomainExtractor.bundled)   // P3-15: "Add Website…"
        // P3-15: Browsers & Sites. The inventory is read when Settings opens (P3-22: AppController re-reads the
        // web-link handlers and re-pushes the policy if they changed); LaunchServices lookups only.
        let browsers = BrowsersSettingsModel(
            store: store, appName: StatusItemController.lookUpAppName, suffixListLoaded: controller.suffixListLoaded,
            ownBundleIDPrefix: KnownSwitchers.ownBundleIDPrefix,
            inventory: {
                BrowserInventorySnapshot(installedCatalog: BrowserInventory.installedCatalogBrowsers(),
                                         webLinkHandlers: controller.refreshWebLinkHandlers())
            },
            support: { controller.browserSupport(for: $0) },
            automation: automation,   // P3-7: the switch, the states, Ask / Open System Settings; silent refresh
            lastFrontBrowser: { controller.lastFrontBrowserID })   // P3-26: the dropdown's default
        let apps = AppsSettingsModel(store: store, appName: StatusItemController.lookUpAppName,
                                     runningApps: Self.runningApps,
                                     ownBundleID: Bundle.main.bundleIdentifier ?? "")
        let fileURL = store.fileURL
        return SettingsWindowController(general: general,
                                        about: AboutInfo(infoDictionary: Bundle.main.infoDictionary ?? [:],
                                                         suffixListVersion: PublicSuffixList.bundledVersion),
                                        tabs: .init(languages: languages, rules: rules,
                                                    convert: ConvertSettingsModel(store: store), apps: apps,
                                                    permissions: permissionsTab, browsers: browsers),
                                        showWelcome: { [weak self] in self?.openOnboarding() },
                                        openSettingsFolder: { Self.openSettingsFolder(fileURL) })
    }

    /// P3-15: About → "Open Settings Folder" (a click only): Finder shows the preferences file, or its folder.
    private static func openSettingsFolder(_ fileURL: URL) {
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        switch SettingsFolderTarget.decide(fileURL: fileURL, exists: exists) {
        case .revealFile(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFolder(let url): NSWorkspace.shared.open(url)
        case .unavailable: NSSound.beep()
        }
    }

    /// P2-25: regular (Dock) apps that are running, for Settings → Apps "Add Running App".
    private static func runningApps() -> [AppCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier else { return nil }
            return AppCandidate(bundleID: id, name: app.localizedName ?? id)
        }
    }

    func start() {
        controller.start()
        statusItem.refresh()
        // P2-26 (001 §6.1): the welcome window, once. It marks itself seen as it shows; never with read-only prefs.
        if OnboardingModel.shouldShowAtLaunch(store) { openOnboarding(firstLaunch: true) }
    }

    func stop() {
        for o in appObservers { NotificationCenter.default.removeObserver(o) }
        appObservers = []
        controller.stop()
        switcher.onChange = nil
        switcher.onSourcesListChanged = nil
        contextMonitor.onChange = nil
        permissions.onChange = nil
        conflicts.onChange = nil
        controller.onDisplayChange = nil
    }
}

/// Lets KeyWatcher's Sendable callbacks (always delivered on main) reach the controller created after it.
@MainActor private final class ControllerBox: Sendable {
    weak var controller: AppController?
}
