// P3-15 (001 §14.8): one browser in Settings → Browsers & Sites, built by `BrowsersSettingsModel`; the view only lays
// it out. The status is this session's `BrowserSupport` in plain words (D15: never stored).

import Foundation

struct BrowserRow: Identifiable, Equatable, Sendable {
    /// What the row's button next to the status does.
    enum StatusAction: Equatable, Sendable {
        case openPermissions
    }

    /// P3-7: whether a "Use Automation" control belongs on this row, and its state.
    enum Automation: Equatable, Sendable {
        /// Chromium / Safari family with an AppleScript dictionary: the opt-in toggle, its state (Off / Allowed /
        /// Denied / Not asked / Checking) and its button (Ask / Open System Settings), from `AutomationControlling`.
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
    /// A second line under the status when it helps ("Turn on Automation below", "Not supported yet").
    let statusHint: String?
    let statusAction: StatusAction?
    /// "Use website rules" (`browsers.siteRulesEnabled`, absent = on).
    let siteRulesOn: Bool
    let automation: Automation

    var isWorking: Bool { support == .works || support == .worksWithAutomation }

    /// P3-7: the Automation state of an `.available` row; nil = no toggle on this row.
    var automationState: BrowserAutomationState? {
        if case .available(let state) = automation { state } else { nil }
    }

    /// P3-7: the line under the "Use Automation" toggle ("Off", "Allowed", "Denied. To allow it, …").
    var automationStatusText: String? { automationState?.statusText(browserName: name) }
}
