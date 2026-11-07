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
    let layoutMaps: UCKeyTranslateLayoutMapProvider   // P2-21/P2-24 read converters from it
    let contextMonitor: ContextMonitor
    let permissions: PermissionsManager
    let conflicts: ConflictDetector
    let keyWatcher: KeyWatcher
    let controller: AppController
    let statusItem: StatusItemController

    private var appObservers: [NSObjectProtocol] = []

    init() {
        let clock = SystemClock()
        let fileURL = (try? PreferencesLocation.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(PreferencesLocation.fileName)
        store = PreferencesStore(fileURL: fileURL, clock: clock)
        switcher = InputSourceSwitcher.makeTIS(clock: clock)
        layoutMaps = UCKeyTranslateLayoutMapProvider()
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

        controller = AppController(switcher: switcher, context: contextMonitor, store: store,
                                   permissions: permissions, conflicts: conflicts, keyWatcher: keyWatcher,
                                   ticker: MainRunLoopTicker(), clock: clock)
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

        // P2-39 (001 §12 W2): Kytkin's own windows are not a context.
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { controller.kytkinDidBecomeActive() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    controller.kytkinDidResignActive(frontmostPID: pid)
                }
            },
        ]
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
