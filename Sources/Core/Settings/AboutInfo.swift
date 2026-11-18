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

    /// P6-0l (owner's exact words): the Acknowledgements popover's title and dedication; the licence credit for the
    /// bundled data stays below them, under `thirdPartyTitle`.
    static let acknowledgementsTitle = "Acknowledgements"
    static let dedication = "Kytkin was built by Tomer Dishon for Ofir W.\n"
        + "So she would never have to pay for a keyboard switcher again — and get a better one."
    static let thirdPartyTitle = "Third-party software"

    static func publicSuffixList(version: String?) -> Acknowledgement {
        // P6-0l: the owner's shorter wording; the list's version (P3-15) stays after it.
        var detail = "Public Suffix List (publicsuffix.org), used unmodified to group website addresses into sites."
        if let version { detail += " Version \(displayVersion(version))." }
        return Acknowledgement(title: "Public Suffix List", detail: detail,
                               license: "Mozilla Public License 2.0",
                               licenseURL: URL(string: "https://mozilla.org/MPL/2.0/") ?? URL(fileURLWithPath: "/"))
    }

    /// P4-3: the update framework (MIT), after the list.
    static let sparkle = Acknowledgement(
        title: "Sparkle",
        detail: "Sparkle (sparkle-project.org), the open-source updater behind \"Keep Kytkin up to date\".",
        license: "MIT License",
        licenseURL: URL(string: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE") ?? URL(fileURLWithPath: "/"))

    /// "github.com/dishontomer5-coder/kytkin"
    var repositoryText: String {
        (repositoryURL.host ?? "") + repositoryURL.path
    }

    static let licenseText = "Free and open source under the MIT License. © 2026 Kytkin contributors."
    /// P6-0g (design v2, About P1): no other app named here (the README keeps the clean-room statement).
    static let cleanRoomText = "An independent project, not affiliated with any other app."
    static let repository = URL(string: "https://github.com/dishontomer5-coder/kytkin") ?? URL(fileURLWithPath: "/")

    /// P6-8 (owner, Clonitt listing): who made Kytkin and where to get help, under the repository link.
    static let developerText = "Made by Tomer Dishon"
    static let issuesTitle = "Report an Issue"
    static let issuesURL = URL(string: "https://github.com/dishontomer5-coder/kytkin/issues")
        ?? URL(fileURLWithPath: "/")
    static let emailTitle = "Email"
    /// The owner chose this address to be public (P6-8).
    static let supportEmail = "dishontomer5@gmail.com"
    static let emailURL = URL(string: "mailto:\(supportEmail)?subject=Kytkin") ?? URL(fileURLWithPath: "/")

    /// P6-0g: the Debug build's name ("Kytkin Dev") shows as "Kytkin"; "Dev" moves to the version line.
    static let devSuffix = " Dev"

    init(infoDictionary info: [String: Any], suffixListVersion: String? = nil) {
        let display = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let bundleName = (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var fullName = display ?? bundleName ?? "Kytkin"
        let isDev = fullName.hasSuffix(Self.devSuffix)
        if isDev { fullName = String(fullName.dropLast(Self.devSuffix.count)) }
        name = fullName
        let short = (info["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        var line: String
        if let build = (info["CFBundleVersion"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            line = "Version \(short) (\(build))"
        } else {
            line = "Version \(short)"
        }
        if isDev { line += " · Dev" }
        version = line
        license = Self.licenseText
        cleanRoom = Self.cleanRoomText
        repositoryURL = Self.repository
        acknowledgements = [Self.publicSuffixList(version: suffixListVersion), Self.sparkle]   // P4-3: + Sparkle
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
