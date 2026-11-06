// P2-16: `PermissionsProviding` (001 §2.2 "PermissionsManager", §6). Owns only the plumbing: the poll timer,
// the refresh notifications, and the two OS seams. Every decision (when to read, the state mapping, change
// detection, coalescing) is in Core's `PermissionMonitor`.
//
// Refresh triggers (001 §2.2): `start()` (launch), every frontmost-app change (NSWorkspace
// didActivateApplication), Kytkin becoming active (NSApplication.didBecomeActive, e.g. back from System
// Settings), and a repeating main-run-loop timer at `PermissionMonitor.pollIntervalNanos`.
// Reads never prompt. `request…`/`openSystemSettings` are for user clicks only (onboarding / Permissions tab).
// Automation per browser is Phase 3 (P3-7): `automation` is always empty for now.
// P2-45: Secure Input is not read or published here; KeyWatcher is its only owner (001 §12.2 W5).
// Never logs.

import AppKit
import Observation

@MainActor @Observable final class PermissionsManager: PermissionsProviding {
    private(set) var status = PermissionStatus()

    // 001 §2.2 names, for the SwiftUI views (P2-26).
    var accessibility: PermissionState { status.grants.accessibility }
    var inputMonitoring: PermissionState { status.grants.inputMonitoring }
    var automation: [String: PermissionState] { status.grants.automation }

    @ObservationIgnored var onChange: (@MainActor (PermissionStatus) -> Void)?
    /// The interval the poll timer runs at, nil while stopped. Read by tests.
    @ObservationIgnored private(set) var scheduledPollNanos: UInt64?

    @ObservationIgnored private let probe: PermissionProbing
    @ObservationIgnored private let requester: PermissionRequesting
    @ObservationIgnored private var monitor: PermissionMonitor
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    @ObservationIgnored private let appCenter: NotificationCenter
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var running = false

    /// No defaults for the seams on purpose: only the composition root (P2-20) passes the real
    /// `SystemPermissionProbe` / `SystemPermissionRequester`; tests pass fakes and private notification centers.
    init(probe: PermissionProbing,
         requester: PermissionRequesting,
         clock: any Clock = SystemClock(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         appCenter: NotificationCenter = .default) {
        self.probe = probe
        self.requester = requester
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        monitor = PermissionMonitor(clock: clock)
    }

    // MARK: - PermissionsProviding

    func start() {
        guard !running else { return }
        running = true
        tokens = [
            observe(workspaceCenter, NSWorkspace.didActivateApplicationNotification, .appActivated),
            observe(appCenter, NSApplication.didBecomeActiveNotification, .kytkinActivated),
        ]
        read(.launch)
        rescheduleTimer()
    }

    func stop() {
        guard running else { return }
        running = false
        tokens.forEach { center, token in center.removeObserver(token) }
        tokens = []
        timer?.invalidate()
        timer = nil
        scheduledPollNanos = nil
    }

    func refresh() {
        read(.manual)
    }

    func setInteractive(_ visible: Bool) {
        guard monitor.interactive != visible else { return }
        monitor.interactive = visible
        // Read now, so the screen opens with fresh rows, not up to 5 s old ones. P2-16 QA: only while running,
        // so nothing is read or published before start() or after stop().
        if visible && running { read(.manual) }
        rescheduleTimer()
    }

    /// User click only.
    func requestAccessibility() {
        monitor.noteRequested(.accessibility)
        requester.requestAccessibility()
        read(.afterRequest)
    }

    /// User click only.
    func requestInputMonitoring() {
        monitor.noteRequested(.inputMonitoring)
        requester.requestInputMonitoring()
        read(.afterRequest)
    }

    /// User click only.
    func openSystemSettings(_ pane: PermissionPane) {
        requester.openSettings(pane.settingsURL)
    }

    // MARK: - Internal (the timer calls it; tests call it directly instead of waiting)

    func pollTick() {
        read(.timer)
    }

    // MARK: - Private

    private func read(_ reason: PermissionRefreshReason) {
        guard monitor.shouldRead(reason) else { return }
        guard let changed = monitor.ingest(probe.read()) else { return }
        status = changed
        onChange?(changed)
    }

    /// Keeps one repeating timer at the monitor's current interval while running.
    private func rescheduleTimer() {
        guard running else { return }
        let interval = monitor.pollIntervalNanos
        guard interval != scheduledPollNanos || timer == nil else { return }
        timer?.invalidate()
        let seconds = TimeInterval(interval) / 1_000_000_000
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        // P2-16: a little tolerance lets macOS batch the wake-ups (energy); 1 s ± 0.1 s is still "about a second".
        timer.tolerance = seconds / 10
        // .common: keep polling while a menu (ours included) is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scheduledPollNanos = interval
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ reason: PermissionRefreshReason) -> (NotificationCenter, NSObjectProtocol) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Both notifications are posted on the main thread.
            MainActor.assumeIsolated { self?.read(reason) }
        }
        return (center, token)
    }
}
