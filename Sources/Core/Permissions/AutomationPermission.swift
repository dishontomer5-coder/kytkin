// P3-7: Automation (Apple Events) permission per browser (001 §14.7). The OS answers per target app with an
// OSStatus from `AEDeterminePermissionToAutomateTarget`; Core maps it and decides when to check. The live seams are
// System/Permissions/SystemAutomationPermission (silent) and SystemAutomationRequester (asks: click only).
//
//   noErr        → granted
//   -1743        → denied              (errAEEventNotPermitted)
//   -1744        → not asked yet       (errAEEventWouldRequireUserConsent)
//   -600         → the browser isn't running (procNotFound): keep the last state
//   anything else → couldn't check: keep the last state
//
// Silent checks run when Settings opens or refreshes (≤ 1 per 5 s per browser), at launch for the browsers the user
// turned on, and when an opted-in browser comes to the front. The prompt is shown ONLY from a click: turning the
// toggle on, or the row's "Ask" button, while that browser runs. If it isn't running, the choice is stored and the
// row says to open the browser and click Ask; Kytkin never asks later on its own.

import Foundation

enum AutomationCheckResult: Sendable, Equatable {
    case granted, denied, notAsked, notRunning, failed

    init(status: Int32) {
        switch status {
        case 0: self = .granted
        case -1743: self = .denied
        case -1744: self = .notAsked
        case -600: self = .notRunning
        default: self = .failed
        }
    }
}

/// Silent: `askUserIfNeeded: false` only. May block briefly, so PermissionsManager calls it off main.
protocol AutomationPermissionChecking: Sendable {
    func check(bundleID: String) -> AutomationCheckResult
}

/// Shows the macOS Automation prompt (`askUserIfNeeded: true`) when it was never answered, and blocks until the user
/// answers. Called off main, and ONLY from a user click (design.md: never prompt without a click).
protocol AutomationPermissionRequesting: Sendable {
    func ask(bundleID: String) -> AutomationCheckResult
}

/// The per-browser states and the check throttle. Pure; PermissionsManager owns one.
struct AutomationPermissionTracker: Sendable, Equatable {
    /// Silent checks of one browser at most this often (§14.7).
    static let minCheckGapNanos: UInt64 = 5_000_000_000

    /// Only browsers that were checked and answered; absent = unknown.
    private(set) var states: [String: PermissionState] = [:]
    private var lastCheckAt: [String: UInt64] = [:]
    private var inFlight: Set<String> = []

    init() {}

    /// A silent check of `bundleID` now? (≤ 1 per 5 s, and never two at once.) Records it when true.
    mutating func beginSilentCheck(_ bundleID: String, now: UInt64) -> Bool {
        guard !inFlight.contains(bundleID) else { return false }
        if let last = lastCheckAt[bundleID], now >= last, now - last < Self.minCheckGapNanos { return false }
        lastCheckAt[bundleID] = now
        inFlight.insert(bundleID)
        return true
    }

    /// A click's request: always allowed. It also counts as a check for the throttle.
    mutating func beginRequest(_ bundleID: String, now: UInt64) {
        lastCheckAt[bundleID] = now
    }

    /// Takes a result. Returns true when `states` changed.
    mutating func ingest(_ bundleID: String, _ result: AutomationCheckResult) -> Bool {
        inFlight.remove(bundleID)
        let next: PermissionState
        switch result {
        case .granted: next = .granted
        case .denied: next = .denied
        case .notAsked: next = .notDetermined
        case .notRunning, .failed: return false   // keep the last state
        }
        guard states[bundleID] != next else { return false }
        states[bundleID] = next
        return true
    }
}

extension PermissionPane {
    /// P3-7: Privacy & Security → Automation (same legacy form as the other panes, see PermissionPane.swift).
    static let automationSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}
