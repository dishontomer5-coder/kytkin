// P3-7: The Automation part of Settings → Browsers & Sites (001 §14.8). `BrowsersSettingsModel` takes
// `any AutomationControlling` and shows, for the browser chosen in the dropdown, `automationState(for:)`; the "Ask"
// button calls `askAutomation`, the "Open System Settings" link `openAutomationSettings`. `refreshAutomation` (silent)
// is for when the tab opens.
//
// P3-26 (plan.md Phase 3 decision 2026-11-08): one global switch, "Use Automation when a browser can't be read"
// (`browsers.useAutomation`, `setUseAutomation`), instead of one per browser. macOS still grants Automation per app,
// so the state and the Ask button stay per browser (in the dropdown).
//
// Rules (plan.md Phase 3 decisions, D9):
//   - Only browsers with a scripting dictionary (Chromium family, Arc, Safari). Zen, Firefox and other Gecko browsers
//     have none: "Automation isn't available for Firefox-based browsers". Orion and unknown browsers: not available.
//     The global switch is simply ignored for them.
//   - Turning the switch on stores the choice and asks macOS (on that click only) for the browsers that support it,
//     are running right now and aren't allowed yet, one at a time (PermissionsManager queues the questions). Every
//     other browser shows "Not asked yet. Open <name>, then click Ask"; Kytkin never asks later on its own, and
//     never when a browser comes to the front.
//   - Turning it off only stores the choice: SitePolicy drops the dialect at once and nothing more is sent.
//   - State per browser: Off · Allowed · Denied (+ Open System Settings) · Not asked (+ Ask) · Checking.

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

    /// The browser supports Automation (Chromium/WebKit with a dictionary).
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

    /// The dropdown's Automation line for this browser, plain English.
    func statusText(browserName name: String) -> String {
        switch status {
        case .notAvailableGecko: "Automation isn't available for Firefox-based browsers."
        case .notAvailable: "Automation isn't available for \(name)."
        case .off: "Off (\"Use Automation\" is off above)"
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
    /// P3-26: user click only (the global "Use Automation" switch). On → asks macOS for the running browsers that
    /// support it and aren't allowed yet, one at a time; off → only stores the choice.
    func setUseAutomation(_ on: Bool)
    /// User click only (the "Ask" button).
    func askAutomation(for bundleID: String)
    /// User click only (the "Open System Settings" link).
    func openAutomationSettings()
    /// Silent; when the tab opens or refreshes.
    func refreshAutomation(for bundleIDs: [String])
}

/// The live `AutomationControlling`: reads the preferences and PermissionsManager, writes `browsers.useAutomation`.
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
                                    optedIn: store.prefs.browsers.useAutomation,
                                    permission: permissions.status.grants.automation[bundleID],
                                    browserIsRunning: isRunning(bundleID))
    }

    /// P3-26: every catalog browser with a scripting dictionary, in a stable order (the order of the questions).
    static let automationBrowserIDs: [String] = BrowserCatalog.all.filter { $0.appleScript != nil }.map(\.bundleID)

    func setUseAutomation(_ on: Bool) {
        guard store.prefs.browsers.useAutomation != on else { return }   // a repeated set never asks again
        store.update { $0.browsers.useAutomation = on }
        // The prompt only on this click, and only for browsers running now (asking a quit browser can't prompt
        // anyway); PermissionsManager shows the questions one at a time.
        guard on else { return }
        for id in Self.automationBrowserIDs where isRunning(id) {
            if permissions.status.grants.automation[id] == .granted { continue }
            permissions.requestAutomation(for: id)
        }
    }

    func askAutomation(for bundleID: String) {
        guard Self.supportsAutomation(bundleID), store.prefs.browsers.useAutomation,
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
