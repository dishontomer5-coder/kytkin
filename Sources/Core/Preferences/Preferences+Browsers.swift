// P2-8: preferences.json `browsers` (001 §4.2, Settings → Browsers & Sites, Phase 3).

import Foundation

extension Preferences {
    struct Browsers: Sendable, Equatable {
        /// With this on, no site rules apply in windows known to be private (001 §3 flow d).
        var ignorePrivateWindowsCompletely = false
        /// Browser bundle ID → the user opted in to the Apple Events URL fallback (R3). Off unless set.
        var appleEventsOptIn: [String: Bool] = [:]

        init() {}
    }
}

extension Preferences.Browsers: Codable {
    private enum CodingKeys: String, CodingKey {
        case ignorePrivateWindowsCompletely, appleEventsOptIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let v = c.lenient(Bool.self, .ignorePrivateWindowsCompletely) { ignorePrivateWindowsCompletely = v }
        if let v = c.lenient([String: Lossy<Bool>].self, .appleEventsOptIn) {
            appleEventsOptIn = v.compactMapValues(\.value)
        }
    }
}
