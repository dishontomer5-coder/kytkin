// P3-15 (001 §14.8): one browser in Settings → Browsers & Sites, built by `BrowsersSettingsModel`; the view only lays
// it out. The status is this session's `BrowserSupport` in plain words (D15: never stored).
// P3-26: the tab shows one browser at a time (the "Browser" dropdown); the rows are the dropdown's choices and the
// chosen one's details. No per-browser switches any more (the global ones are on the model).

import Foundation

struct BrowserRow: Identifiable, Equatable, Sendable {
    /// What the row's button next to the status does.
    enum StatusAction: Equatable, Sendable {
        case openPermissions
    }

    /// P3-7: whether this browser supports Automation, and its state.
    enum Automation: Equatable, Sendable {
        /// Chromium / Safari family with an AppleScript dictionary: its state (Off / Allowed / Denied / Not asked /
        /// Checking) and its button (Ask / Open System Settings), from `AutomationControlling`.
        case available(BrowserAutomationState)
        /// No dictionary (Firefox family, Orion, other browsers): this line instead.
        case notAvailable(String)
    }

    let bundleID: String
    var id: String { bundleID }
    let name: String
    /// "Chromium-based", "Firefox-based", "Safari-based", "Other browser (best effort)", plus " · not yet tested" for
    /// a catalog browser whose read path hasn't been seen working on a real Mac.
    let engineText: String
    /// False for a web-link handler outside the catalog ("best effort", owner answer 2).
    let isCatalogued: Bool
    let support: BrowserSupport
    let statusText: String
    /// A second line under the status when it helps ("Turn on Automation above", "Not supported yet").
    let statusHint: String?
    let statusAction: StatusAction?
    let automation: Automation

    var isWorking: Bool { support == .works || support == .worksWithAutomation }

    /// P3-7: the Automation state of an `.available` row; nil = this browser doesn't support Automation.
    var automationState: BrowserAutomationState? {
        if case .available(let state) = automation { state } else { nil }
    }

    /// P3-7: the browser's Automation line ("Off", "Allowed", "Denied. To allow it, …").
    var automationStatusText: String? { automationState?.statusText(browserName: name) }
}
