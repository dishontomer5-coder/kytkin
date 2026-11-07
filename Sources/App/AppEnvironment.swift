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
    let conflicts: ConflictDetector
    let keyWatcher: KeyWatcher
    let convert: ConvertDispatcher
    let controller: AppController
    let statusItem: StatusItemController
    /// P2-23: built on first `openSettings`, then reused.
    private var settingsWindow: SettingsWindowController?

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
        contextMonitor = ContextMonitor(source: WorkspaceAppActivationSource(), clock: clock)
        permissions = PermissionsManager(probe: SystemPermissionProbe(), requester: SystemPermissionRequester(),
                                         clock: clock)
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
            })
        convert = ConvertDispatcher(controller: convertController, maps: layoutCatalog)   // P2-32: system, else imported

        controller = AppController(switcher: switcher, context: contextMonitor, store: store,
                                   permissions: permissions, conflicts: conflicts, keyWatcher: keyWatcher,
                                   ticker: MainRunLoopTicker(), convert: convert, clock: clock,
                                   scheduler: MainRunLoopOneShot(),          // P2-52 item 1
                                   frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier })
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
        controller.onDisplayChange = { statusItem.refresh() }
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

    private func makeSettingsWindow() -> SettingsWindowController {
        let switcher = self.switcher
        // P2-23: SMAppServiceLoginItems only reads the status here; register/unregister run on the user's toggle.
        let general = GeneralSettingsModel(store: store, loginItems: SMAppServiceLoginItems(),
                                           sources: { switcher.sources(includeDisabled: false) })
        // P2-24: reads the layout lists only on refresh (when Settings opens); files only on the user's clicks.
        let languages = LanguagesSettingsModel(store: store, imported: importedLayouts, catalog: layoutCatalog,
                                               fileSystem: importedLayouts.fileSystem,
                                               inputMethods: { switcher.sources(includeDisabled: false) })
        // P2-25: Rules, Convert and Apps. Names come from LaunchServices; running apps only when Settings opens.
        let rules = RulesSettingsModel(store: store, appName: StatusItemController.lookUpAppName,
                                       sources: { switcher.sources(includeDisabled: true) })
        let apps = AppsSettingsModel(store: store, appName: StatusItemController.lookUpAppName,
                                     runningApps: Self.runningApps,
                                     ownBundleID: Bundle.main.bundleIdentifier ?? "")
        return SettingsWindowController(general: general,
                                        about: AboutInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]),
                                        tabs: .init(languages: languages, rules: rules,
                                                    convert: ConvertSettingsModel(store: store), apps: apps))
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
