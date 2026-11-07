// P3-15 (001 §14.8): one browser in Settings → Browsers & Sites, built by `BrowsersSettingsModel`; the view only lays
// it out. The status is this session's `BrowserSupport` in plain words (D15: never stored).

import Foundation

struct BrowserRow: Identifiable, Equatable, Sendable {
    /// What the row's button next to the status does.
    enum StatusAction: Equatable, Sendable {
        case openPermissions
    }

    /// P3-7's slot: whether a "Use Automation" control belongs on this row.
    enum Automation: Equatable, Sendable {
        /// Chromium / Safari family with an AppleScript dictionary: P3-7 puts the opt-in toggle here.
        case available(AppleScriptDialect)
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
}
