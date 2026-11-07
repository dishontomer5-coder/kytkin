// P3-7: The Automation part of a Settings → Browsers & Sites row (001 §14.8), for P3-15 to bind to. P3-15's
// `BrowsersSettingsModel` takes `any AutomationControlling` and shows, per browser, `automationState(for:)`; its
// "Use Automation" toggle calls `setAutomationEnabled`, the "Ask" button `askAutomation`, the "Open System Settings"
// link `openAutomationSettings`. `refreshAutomation` (silent) is for when the tab opens.
//
// Rules (plan.md Phase 3 decision, D9):
//   - Only browsers with a scripting dictionary (Chromium family, Arc, Safari). Zen, Firefox and other Gecko browsers
//     have none: "Automation isn't available for Firefox-based browsers". Orion and unknown browsers: not available.
//   - Turning it on stores the choice and, if the browser is running, asks macOS (the prompt appears on that click
//     only). Not running → the row says "Open <name>, then click Ask"; Kytkin never asks later on its own.
//   - Turning it off only stores the choice: SitePolicy drops the dialect at once and nothing more is sent.
//   - State: Off · Allowed · Denied (+ Open System Settings) · Not asked (+ Ask) · Checking.

import Foundation
import Observation

/// What one browser row shows about Automation.
struct BrowserAutomationState: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case notAvailableGecko   // Zen, Firefox: no AppleScript
        case notAvailable        // a browser with no dictionary Kytkin knows (Orion, "other" browsers)
        case off
        case allowed
        case denied
        case notAsked
        case checking            // turned on, not checked yet
    }

    enum Action: Sendable, Equatable {
        case ask                 // `askAutomation`
        case openSystemSettings  // `openAutomationSettings`
    }

    let status: Status
    /// The browser was running at the last check (Ask needs it running).
    let browserIsRunning: Bool

    /// The toggle can be used (Chromium/WebKit with a dictionary).
    var isAvailable: Bool { status != .notAvailableGecko && status != .notAvailable }
    var isOn: Bool { isAvailable && status != .off }

    /// The button next to the state, if any, and whether it can be clicked now.
    var action: Action? {
        switch status {
        case .denied: .openSystemSettings
        case .notAsked: .ask
        default: nil
        }
    }

    var actionEnabled: Bool { action == .ask ? browserIsRunning : action != nil }

    func actionTitle() -> String? {
        switch action {
        case .ask: "Ask"
        case .openSystemSettings: "Open System Settings"
        case nil: nil
        }
    }

    /// The row's state text, plain English.
    func statusText(browserName name: String) -> String {
        switch status {
        case .notAvailableGecko: "Automation isn't available for Firefox-based browsers."
        case .notAvailable: "Automation isn't available for \(name)."
        case .off: "Off"
        case .allowed: "Allowed"
        case .denied:
            "Denied. To allow it, open System Settings → Privacy & Security → Automation and turn on \(name) under Kytkin."
        case .notAsked:
            browserIsRunning ? "Not asked yet. Click Ask, then OK in the box macOS shows."
                : "Not asked yet. Open \(name), then click Ask."
        case .checking:
            browserIsRunning ? "Checking…" : "Open \(name) to check."
        }
    }

    static func make(bundleID: String, optedIn: Bool, permission: PermissionState?,
                     browserIsRunning: Bool) -> BrowserAutomationState {
        guard let known = BrowserCatalog.known[bundleID], known.appleScript != nil else {
            let gecko = BrowserCatalog.known[bundleID]?.engine == .gecko
            return BrowserAutomationState(status: gecko ? .notAvailableGecko : .notAvailable,
                                          browserIsRunning: browserIsRunning)
        }
        guard optedIn else { return BrowserAutomationState(status: .off, browserIsRunning: browserIsRunning) }
        let status: Status = switch permission {
        case .granted: .allowed
        case .denied: .denied
        case .notDetermined: .notAsked
        case .unknown, nil: browserIsRunning ? .checking : .notAsked
        }
        return BrowserAutomationState(status: status, browserIsRunning: browserIsRunning)
    }
}

/// The seam P3-15 binds to (001 §14.12 "an `AutomationControlling` seam for P3-15").
@MainActor protocol AutomationControlling: AnyObject {
    func automationState(for bundleID: String) -> BrowserAutomationState
    /// User click only (the "Use Automation" toggle).
    func setAutomationEnabled(_ on: Bool, for bundleID: String)
    /// User click only (the "Ask" button).
    func askAutomation(for bundleID: String)
    /// User click only (the "Open System Settings" link).
    func openAutomationSettings()
    /// Silent; when the tab opens or refreshes.
    func refreshAutomation(for bundleIDs: [String])
}

/// The live `AutomationControlling`: reads the preferences and PermissionsManager, writes `browsers.appleEventsOptIn`.
/// Observable through the store and the permissions object it reads.
@MainActor final class BrowserAutomationController: AutomationControlling {
    private let store: PreferencesStore
    private let permissions: any PermissionsProviding
    private let isRunning: @MainActor (String) -> Bool

    /// - Parameter isRunning: whether the browser runs now (NSRunningApplication in the app; a fake in tests).
    init(store: PreferencesStore, permissions: any PermissionsProviding,
         isRunning: @escaping @MainActor (String) -> Bool) {
        self.store = store
        self.permissions = permissions
        self.isRunning = isRunning
    }

    static func supportsAutomation(_ bundleID: String) -> Bool {
        BrowserCatalog.known[bundleID]?.appleScript != nil
    }

    func automationState(for bundleID: String) -> BrowserAutomationState {
        BrowserAutomationState.make(bundleID: bundleID,
                                    optedIn: store.prefs.browsers.appleEventsOptIn[bundleID] == true,
                                    permission: permissions.status.grants.automation[bundleID],
                                    browserIsRunning: isRunning(bundleID))
    }

    func setAutomationEnabled(_ on: Bool, for bundleID: String) {
        guard Self.supportsAutomation(bundleID) else { return }
        store.update { $0.browsers.appleEventsOptIn[bundleID] = on ? true : nil }
        // The prompt only on this click, and only if the browser runs (asking a quit browser can't prompt anyway).
        guard on, isRunning(bundleID) else { return }
        if permissions.status.grants.automation[bundleID] == .granted { return }
        permissions.requestAutomation(for: bundleID)
    }

    func askAutomation(for bundleID: String) {
        guard Self.supportsAutomation(bundleID), store.prefs.browsers.appleEventsOptIn[bundleID] == true,
              isRunning(bundleID) else { return }
        permissions.requestAutomation(for: bundleID)
    }

    func openAutomationSettings() {
        permissions.openAutomationSettings()
    }

    func refreshAutomation(for bundleIDs: [String]) {
        permissions.refreshAutomation(for: Set(bundleIDs.filter(Self.supportsAutomation)))
    }
}
