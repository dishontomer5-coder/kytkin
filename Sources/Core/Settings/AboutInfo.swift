// P2-23: What Settings → About shows (001 §5.2): name, version, MIT license, the clean-room statement (from the
// README) and the project's GitHub address. Built from the bundle's Info.plist, so it is tested with a dictionary.

import Foundation

struct AboutInfo: Equatable, Sendable {
    let name: String
    let version: String
    let license: String
    let cleanRoom: String
    let repositoryURL: URL

    /// "github.com/dishontomer5-coder/kytkin"
    var repositoryText: String {
        (repositoryURL.host ?? "") + repositoryURL.path
    }

    static let licenseText = "Free and open source under the MIT License. Copyright © 2026 Kytkin contributors."
    static let cleanRoomText = "Kytkin is an independent, clean-room implementation inspired by the idea of apps "
        + "like FlicKey. It contains no code, text, or assets from FlicKey."
    static let repository = URL(string: "https://github.com/dishontomer5-coder/kytkin") ?? URL(fileURLWithPath: "/")

    init(infoDictionary info: [String: Any]) {
        let display = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bundleName = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        name = display ?? bundleName ?? "Kytkin"
        let short = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        if let build = (info["CFBundleVersion"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            version = "Version \(short) (\(build))"
        } else {
            version = "Version \(short)"
        }
        license = Self.licenseText
        cleanRoom = Self.cleanRoomText
        repositoryURL = Self.repository
    }
}
