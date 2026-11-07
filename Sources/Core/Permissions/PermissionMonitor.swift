// P2-16: The decisions behind PermissionsManager (001 §2.2 "PermissionsManager", §6): when to read, how a
// raw reading becomes a `PermissionStatus`, and whether anything changed. Pure: time comes from the injected
// `Clock`, readings from the caller. The System class only owns the timer, the notifications and the OS calls.
//
// When to read (001 §2.2 refresh triggers; there is no system notification for a grant change):
//   - launch, Kytkin becoming active, the poll timer, right after a request, and an explicit refresh: always.
//   - another app becoming frontmost: at most once per `minEventGapNanos`. A burst of activations (⌘Tab
//     through several apps, a Space swipe) costs one read. A skipped read is never lost: the timer re-reads.
//
// Poll interval (`pollIntervalNanos`):
//   - 1 s while the onboarding or Permissions screen is visible (`interactive`), so the row turns green
//     about a second after the user flips the switch in System Settings (001 §6.1 step 3).
//   - otherwise every `backgroundPollNanos` (5 s), so a revoke is noticed even without an app change (§6.2).
// P2-45: Secure Input is not polled here. KeyWatcher owns it (tap thread, 1 s) and publishes
// `KeyWatcherStatus.secureInputOn` (001 §12.2 W5).
//
// Mapping a reading to `PermissionState` (the OS answers only yes/no):
//   - true → `.granted`.
//   - false → `.denied` once Kytkin has asked for that permission during this run (the request button was
//     clicked), else `.notDetermined` ("not granted, not asked yet"). The system prompt appears at most once
//     ever, so a `.notDetermined` permission may still have been denied in an earlier run: the UI offers the
//     System Settings deep link for both. `.unknown` only before the first read.
//
// Input Monitoring "Quit & Reopen": granted now, but seen not granted at any earlier read of this run
// → `inputMonitoringNeedsRelaunch` (a listen-only tap usually fails until a relaunch, keyboard-event-tap.md §1).
// P2-16 QA: "any earlier read", not only the first: granted at launch → revoked → granted again is the same
// situation for the tap (KeyWatcher dropped it on the revoke and must create a new one). It is a hint only; the
// UI shows "Quit & Reopen" only while the tap mode KeyWatcher achieved is still below the desired one.
// P2-64: never while Accessibility is trusted (on macOS 26 it alone makes the Input Monitoring preflight read true).

import Foundation

struct PermissionMonitor {
    static let interactivePollNanos: UInt64 = 1_000_000_000
    static let backgroundPollNanos: UInt64 = 5_000_000_000
    /// App-activation reads closer together than this are coalesced.
    static let minEventGapNanos: UInt64 = 250_000_000

    /// The last published status. All `.unknown` until the first `ingest`.
    private(set) var status = PermissionStatus()
    /// True once a reading has been ingested.
    private(set) var hasRead = false
    /// The onboarding or Permissions screen is visible.
    var interactive = false

    private let clock: any Clock
    private var lastReadAtNanos: UInt64?
    private var requested: Set<PermissionPane> = []
    /// Some read of this run saw Input Monitoring not granted.
    private var inputMonitoringSeenNotGranted = false

    init(clock: any Clock) {
        self.clock = clock
    }

    /// How often the caller's timer should fire right now.
    var pollIntervalNanos: UInt64 {
        interactive ? Self.interactivePollNanos : Self.backgroundPollNanos
    }

    /// Whether a trigger should cause a read now. Only app activations are coalesced.
    func shouldRead(_ reason: PermissionRefreshReason) -> Bool {
        guard reason == .appActivated, let last = lastReadAtNanos else { return true }
        let now = clock.nowNanos
        return now < last || now - last >= Self.minEventGapNanos
    }

    /// Records that the user clicked the request button for `pane`, so a later "not granted" reads as `.denied`.
    mutating func noteRequested(_ pane: PermissionPane) {
        requested.insert(pane)
    }

    /// Takes one silent reading. Returns the new status when it differs from the published one, else nil.
    mutating func ingest(_ reading: PermissionReading) -> PermissionStatus? {
        lastReadAtNanos = clock.nowNanos
        hasRead = true
        if !reading.inputMonitoringGranted { inputMonitoringSeenNotGranted = true }

        var next = status
        next.grants.accessibility = state(reading.accessibilityTrusted, .accessibility)
        next.grants.inputMonitoring = state(reading.inputMonitoringGranted, .inputMonitoring)
        // A revoke clears the hint: there is nothing to reopen for.
        // P2-64: on macOS 26 Accessibility alone makes the Input Monitoring preflight read true, so granting
        // Accessibility would look like a fresh Input Monitoring grant. While Accessibility is trusted the active tap
        // covers it and nothing needs a relaunch.
        next.inputMonitoringNeedsRelaunch = reading.inputMonitoringGranted && inputMonitoringSeenNotGranted
            && !reading.accessibilityTrusted

        guard next != status else { return nil }
        status = next
        return next
    }

    private func state(_ granted: Bool, _ pane: PermissionPane) -> PermissionState {
        if granted { return .granted }
        return requested.contains(pane) ? .denied : .notDetermined
    }
}
