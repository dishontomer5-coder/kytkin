// P2-23: What Settings → About shows (001 §5.2): name, version, MIT license, the clean-room statement (from the
// README) and the project's GitHub address. Built from the bundle's Info.plist, so it is tested with a dictionary.
// P3-15 (001 §14.8, P3-4): acknowledgements for the bundled data (the Public Suffix List, MPL-2.0, with its version
// from the file's header), and "Open Settings Folder" (`SettingsFolderTarget`, on click only).

import Foundation

struct AboutInfo: Equatable, Sendable {
    let name: String
    let version: String
    let license: String
    let cleanRoom: String
    let repositoryURL: URL
    /// P3-15: third-party data shipped inside Kytkin.
    let acknowledgements: [Acknowledgement]

    struct Acknowledgement: Equatable, Sendable, Identifiable {
        let title: String
        let detail: String
        let license: String
        let licenseURL: URL
        var id: String { title }
    }

    /// "2026-11-06_09-01-47_UTC" → "2026-11-06"; anything else is shown as it is.
    static func displayVersion(_ raw: String) -> String {
        let date = raw.prefix(10)
        let isDate = date.count == 10 && date.enumerated().allSatisfy { i, c in
            (i == 4 || i == 7) ? c == "-" : c.isASCII && c.isNumber
        }
        return isDate ? String(date) : raw
    }

    static func publicSuffixList(version: String?) -> Acknowledgement {
        var detail = "Kytkin uses the Public Suffix List (publicsuffix.org) to group website addresses into sites, "
            + "so www.ynet.co.il and news.ynet.co.il share the rule for ynet.co.il. Shipped unmodified."
        if let version { detail += " Version \(displayVersion(version))." }
        return Acknowledgement(title: "Public Suffix List", detail: detail,
                               license: "Mozilla Public License 2.0 (MPL-2.0)",
                               licenseURL: URL(string: "https://mozilla.org/MPL/2.0/") ?? URL(fileURLWithPath: "/"))
    }

    /// "github.com/dishontomer5-coder/kytkin"
    var repositoryText: String {
        (repositoryURL.host ?? "") + repositoryURL.path
    }

    static let licenseText = "Free and open source under the MIT License. Copyright © 2026 Kytkin contributors."
    static let cleanRoomText = "Kytkin is an independent, clean-room implementation inspired by the idea of apps "
        + "like FlicKey. It contains no code, text, or assets from FlicKey."
    static let repository = URL(string: "https://github.com/dishontomer5-coder/kytkin") ?? URL(fileURLWithPath: "/")

    init(infoDictionary info: [String: Any], suffixListVersion: String? = nil) {
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
        acknowledgements = [Self.publicSuffixList(version: suffixListVersion)]
    }
}

/// P3-15: what About → "Open Settings Folder" shows in Finder: the preferences file selected when it exists, else its
/// folder, else nothing (Kytkin never creates the folder just to show it). Decided on the click, never before.
enum SettingsFolderTarget: Equatable, Sendable {
    case revealFile(URL)
    case openFolder(URL)
    case unavailable

    static func decide(fileURL: URL, exists: (URL) -> Bool) -> SettingsFolderTarget {
        if exists(fileURL) { return .revealFile(fileURL) }
        let folder = fileURL.deletingLastPathComponent()
        return exists(folder) ? .openFolder(folder) : .unavailable
    }
}
