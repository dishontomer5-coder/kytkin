// P4-3: what Kytkin tells its updater (Sparkle), worked out from the user's one choice, "Keep Kytkin up to date".
// Pure, so the mapping and the Info.plist rules are unit-tested; System/Updates/SparkleUpdater applies it.
//
// - Off (the default): no scheduled check, nothing downloaded. Sparkle makes no network request at all.
// - On: Sparkle asks the appcast once a day. A newer version becomes one quiet menu line; it downloads and installs only
//   after the user clicks Install in Sparkle's window. Never an automatic download or install.
// - Either way: no system profile, a fixed User-Agent with Kytkin's version, and a fixed Accept-Language (the system
//   would otherwise send the Mac's preferred languages, P6-3 QA). Nothing about the user is sent.

import Foundation

struct UpdaterConfiguration: Equatable, Sendable {
    var automaticallyChecks: Bool
    var automaticallyDownloads: Bool
    var checkInterval: TimeInterval
    var sendsSystemProfile: Bool
    var userAgent: String
    var httpHeaders: [String: String]

    static let dailyInterval: TimeInterval = 24 * 60 * 60

    /// The appcast: an asset of the latest GitHub release, so this address never changes (scripts/make-appcast).
    static let feedURL = "https://github.com/dishontomer5-coder/kytkin/releases/latest/download/appcast.xml"

    static func forUser(keepUpToDate: Bool, appVersion: String) -> UpdaterConfiguration {
        UpdaterConfiguration(automaticallyChecks: keepUpToDate, automaticallyDownloads: false,
                             checkInterval: dailyInterval, sendsSystemProfile: false,
                             userAgent: "Kytkin/\(appVersion)", httpHeaders: ["Accept-Language": "en"])
    }

    /// The Sparkle keys Config/Info.plist must carry (checked by the tests against the real file): nothing automatic
    /// before Kytkin applies the user's choice, and no "may we check?" prompt from Sparkle (the key being present).
    static let requiredInfoPlist: [String: PlistValue] = [
        "SUFeedURL": .string(feedURL),
        "SUEnableAutomaticChecks": .bool(false),
        "SUAutomaticallyUpdate": .bool(false),
        "SUAllowsAutomaticUpdates": .bool(false),
        "SUEnableSystemProfiling": .bool(false),
        "SUScheduledCheckInterval": .int(Int(dailyInterval)),
        // The downloaded disk image's EdDSA signature is checked before it is even opened.
        "SUVerifyUpdateBeforeExtraction": .bool(true),
        // The appcast itself is signed with the same key (scripts/make-appcast), so its notes can't be changed either.
        "SURequireSignedFeed": .bool(true),
    ]

    enum PlistValue: Equatable, Sendable {
        case bool(Bool), int(Int), string(String)

        /// A plist number is an NSNumber: compared by its kind too, so a 1 is never taken for `true`.
        func matches(_ value: Any) -> Bool {
            switch self {
            case .bool(let want):
                guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
                return n.boolValue == want
            case .int(let want):
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
                return n.intValue == want
            case .string(let want):
                return (value as? String) == want
            }
        }
    }

    /// Every way `info` differs from `requiredInfoPlist` (empty = fine).
    static func infoPlistProblems(_ info: [String: Any]) -> [String] {
        requiredInfoPlist.keys.sorted().compactMap { key in
            guard let want = requiredInfoPlist[key] else { return nil }
            guard let got = info[key] else { return "\(key) is missing" }
            return want.matches(got) ? nil : "\(key) is \(got), should be \(want)"
        }
    }

    /// `SUPublicEDKey` must be a real Ed25519 public key (base64 of 32 bytes). The placeholder, an empty or a broken
    /// value turns updates off in the app (Sparkle would refuse to start) and stops scripts/package-dmg from signing.
    static func isUsablePublicKey(_ key: String?) -> Bool {
        guard let key, let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return data.count == 32
    }
}
