// P2-8: preferences.json `browsers` (001 §4.2, Settings → Browsers & Sites, Phase 3).

import Foundation

extension Preferences {
    struct Browsers: Sendable, Equatable {
        /// With this on, no site rules apply in windows known to be private (001 §3 flow d).
        var ignorePrivateWindowsCompletely = false
        /// P3-9 (001 §4.2, §14.6): browser bundle ID → "Remember languages for websites". Absent = on; off → no watch
        /// request (SitePolicy), so that browser is app-only.
        var siteRulesEnabled: [String: Bool] = [:]
        /// Browser bundle ID → the user opted in to the Apple Events URL fallback (R3). Off unless set.
        var appleEventsOptIn: [String: Bool] = [:]

        init() {}
    }
}

extension Preferences.Browsers: Codable {
    private enum CodingKeys: String, CodingKey {
        case ignorePrivateWindowsCompletely, siteRulesEnabled, appleEventsOptIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .ignorePrivateWindowsCompletely) { ignorePrivateWindowsCompletely = v }
        // P3-9: lenient per entry, like `appleEventsOptIn`: a mistyped value drops only that browser (= on).
        if let v = c.lenient([String: Lossy<Bool>].self, .siteRulesEnabled) {
            siteRulesEnabled = v.compactMapValues(\.value)
        }
        if let v = c.lenient([String: Lossy<Bool>].self, .appleEventsOptIn) {
            appleEventsOptIn = v.compactMapValues(\.value)
        }
    }
}
