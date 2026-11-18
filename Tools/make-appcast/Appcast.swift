// P4-3: writes build/appcast.xml, the one-item Sparkle feed uploaded next to each release's DMG (scripts/make-appcast).
// Pure Foundation, so the output is unit-tested (Tests/KytkinTests/Updates/AppcastTests.swift, a fake signature).
// A release tool only: compiled by scripts/make-appcast and into the tests, never into Kytkin.app.
//
// The app reads https://github.com/<repo>/releases/latest/download/appcast.xml, which GitHub redirects to this file
// in the newest release, so one item (the newest version) is all the feed needs.

import Foundation

struct AppcastRelease: Equatable {
    /// CFBundleShortVersionString, "1.1.0".
    var version: String
    /// CFBundleVersion, "2": what Sparkle compares (it must grow with every release).
    var build: String
    /// The DMG's size in bytes.
    var length: Int
    /// Sparkle's sign_update output: the base64 EdDSA (Ed25519) signature of the DMG.
    var edSignature: String
    var minimumSystemVersion = "14.0"
    var published: Date
    /// This version's CHANGELOG.md section (Markdown), shown in Sparkle's update window. nil = none.
    var notesMarkdown: String?
}

enum Appcast {
    static let repository = "dishontomer5-coder/kytkin"

    static func downloadURL(version: String) -> String {
        "https://github.com/\(repository)/releases/download/v\(version)/Kytkin-\(version).dmg"
    }

    static func releasePageURL(version: String) -> String {
        "https://github.com/\(repository)/releases/tag/v\(version)"
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case badVersion(String), badBuild(String), badLength(Int), badSignature

        var description: String {
            switch self {
            case .badVersion(let v): "the version \"\(v)\" isn't like 1.2.3"
            case .badBuild(let b): "the build number \"\(b)\" isn't a whole number"
            case .badLength(let n): "the DMG size \(n) isn't a positive number of bytes"
            case .badSignature: "the EdDSA signature isn't 64 bytes of base64 (sign_update's output)"
            }
        }
    }

    static func validate(_ release: AppcastRelease) throws {
        let parts = release.version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil })
        else { throw Problem.badVersion(release.version) }
        guard !release.build.isEmpty, release.build.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw Problem.badBuild(release.build)
        }
        guard release.length > 0 else { throw Problem.badLength(release.length) }
        guard Data(base64Encoded: release.edSignature)?.count == 64 else { throw Problem.badSignature }
    }

    /// The feed. Throws when `release` isn't valid, so a broken feed is never written.
    static func xml(for release: AppcastRelease) throws -> String {
        try validate(release)
        let v = release.version
        var item = [
            "      <title>Kytkin \(escape(v))</title>",
            "      <pubDate>\(rfc822(release.published))</pubDate>",
            "      <sparkle:version>\(escape(release.build))</sparkle:version>",
            "      <sparkle:shortVersionString>\(escape(v))</sparkle:shortVersionString>",
            "      <sparkle:minimumSystemVersion>\(escape(release.minimumSystemVersion))</sparkle:minimumSystemVersion>",
            "      <sparkle:fullReleaseNotesLink>\(escape(releasePageURL(version: v)))</sparkle:fullReleaseNotesLink>",
        ]
        if let notes = release.notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            item.append("      <description sparkle:format=\"markdown\">\(escape(notes))</description>")
        }
        item.append("      <enclosure url=\"\(escape(downloadURL(version: v)))\" length=\"\(release.length)\" "
            + "type=\"application/octet-stream\" sparkle:edSignature=\"\(escape(release.edSignature))\"/>")
        return """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel>
                <title>Kytkin</title>
                <link>https://github.com/\(repository)</link>
                <description>Kytkin updates</description>
                <language>en</language>
                <item>
            \(item.joined(separator: "\n"))
                </item>
              </channel>
            </rss>

            """
    }

    /// `sign_update <dmg>` prints `sparkle:edSignature="…" length="…"`; nil when it printed anything else.
    static func parseSignUpdateOutput(_ output: String) -> (signature: String, length: Int)? {
        func value(_ name: String) -> String? {
            guard let start = output.range(of: "\(name)=\"") else { return nil }
            let rest = output[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        guard let signature = value("sparkle:edSignature"), let length = value("length").flatMap({ Int($0) }) else {
            return nil
        }
        return (signature, length)
    }

    /// The `## <version>` section of CHANGELOG.md (up to the next `## `), without its heading. nil when absent.
    static func changelogSection(_ changelog: String, version: String) -> String? {
        var lines: [Substring] = []
        var inside = false
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inside { break }
                let title = line.dropFirst(3)
                inside = title == version || title.hasPrefix("\(version) ")
                continue
            }
            if inside { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }
}
