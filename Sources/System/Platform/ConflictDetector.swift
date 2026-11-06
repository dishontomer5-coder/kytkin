// P2-19: ConflictDetector (001 §2.2, research input-source-switching.md §4 + Risks, owner decision P2-38).
// Detects (a) other input switchers running (KnownSwitchers, by bundle ID/name from NSWorkspace) and
// (b) macOS per-document input, and publishes `Conflicts` for the menu warning and the learning pause.
// Thin by design: it turns notifications and reads into `ConflictEvent`s; `ConflictState` decides.
//
// Triggers, all on the main actor:
//   - start(): a launch scan of NSWorkspace.runningApplications + a preference read.
//   - workspace didLaunch / didTerminate → launched / terminated (the switcher diff).
//   - workspace didActivateApplication and Kytkin's own didBecomeActive → re-read the preference. Changing
//     the setting means using System Settings and then coming back to another app, so this catches it.
//   - a modest poll (30 s) → re-read + full rescan, healing any missed notification.
//   - refresh() → the same, on demand (the menu, P2-22).
// Detection only: it never quits, activates, hides or messages another app, and never writes a preference.

import AppKit
import Observation

@MainActor @Observable final class ConflictDetector: ConflictDetecting {
    static let defaultPollInterval: TimeInterval = 30

    private(set) var conflicts = Conflicts.none
    private(set) var repeatedFights = 0
    @ObservationIgnored var onChange: (@MainActor (Conflicts) -> Void)?

    /// 001 §2.2 names.
    var runningSwitchers: [String] { conflicts.runningSwitchers }
    var perDocumentInputEnabled: Bool { conflicts.perDocumentInputEnabled }

    @ObservationIgnored private var state: ConflictState
    @ObservationIgnored private var fights = FightCounter()
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    @ObservationIgnored private let appCenter: NotificationCenter
    @ObservationIgnored private let runningApps: @MainActor () -> [RunningAppInfo]
    @ObservationIgnored private let readPerDocumentInput: @MainActor () -> Bool
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?

    /// Tests inject private notification centers and fakes; the app uses the defaults.
    /// `pollInterval <= 0` turns the poll off.
    init(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         appCenter: NotificationCenter = .default,
         runningApps: @escaping @MainActor () -> [RunningAppInfo] = ConflictDetector.workspaceRunningApps,
         readPerDocumentInput: @escaping @MainActor () -> Bool = PerDocumentInputReader.isEnabled,
         entries: [KnownSwitcher] = KnownSwitchers.entries,
         clock: any Clock = SystemClock(),
         pollInterval: TimeInterval = ConflictDetector.defaultPollInterval) {
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        self.runningApps = runningApps
        self.readPerDocumentInput = readPerDocumentInput
        self.clock = clock
        self.pollInterval = pollInterval
        state = ConflictState(entries: entries)
    }

    func start() {
        guard tokens.isEmpty else { return }
        tokens = [
            observeWorkspace(NSWorkspace.didLaunchApplicationNotification) { detector, app in
                if let app { detector.apply(.launched(app)) }
            },
            observeWorkspace(NSWorkspace.didTerminateApplicationNotification) { detector, app in
                if let app { detector.apply(.terminated(pid: app.pid)) }
            },
            observeWorkspace(NSWorkspace.didActivateApplicationNotification) { detector, _ in
                detector.readPreference()
            },
            appCenter.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                  queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readPreference() }
            },
        ]
        if pollInterval > 0 {
            let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = pollInterval / 5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        }
        refresh()
    }

    func stop() {
        tokens.forEach { token in
            workspaceCenter.removeObserver(token)
            appCenter.removeObserver(token)
        }
        tokens = []
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        apply(.scan(runningApps()))
        readPreference()
    }

    func noteOurSwitch() {
        fights.ourSwitch(atNanos: clock.nowNanos)
    }

    func noteExternalSwitch() {
        if fights.externalSwitch(atNanos: clock.nowNanos) { repeatedFights = fights.count }
    }

    /// The real running-apps list (headless, no permission). Background-only helpers are included on
    /// purpose: a switcher may run as a faceless agent.
    static func workspaceRunningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.map(info)
    }

    // MARK: - Private

    private func readPreference() {
        apply(.perDocumentInput(readPerDocumentInput()))
    }

    private func apply(_ event: ConflictEvent) {
        guard let changed = state.apply(event) else { return }
        conflicts = changed
        onChange?(changed)
    }

    nonisolated private static func info(_ app: NSRunningApplication) -> RunningAppInfo {
        RunningAppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    private func observeWorkspace(_ name: Notification.Name,
                                  _ handle: @escaping @MainActor (ConflictDetector, RunningAppInfo?) -> Void)
        -> NSObjectProtocol {
        workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            // Read the Sendable values here, then hop: NSWorkspace posts these on the main thread.
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let info = running.map(ConflictDetector.info)
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self, info)
            }
        }
    }
}
