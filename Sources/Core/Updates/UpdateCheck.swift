// P6-3: the optional update check, the only network call Kytkin may make (CLAUDE.md, design.md). Pure Core over an
// injected HTTP client, so it is unit-tested with a fake (no real network in tests).
//
// - Off until the user opts in (`general.updateCheckOptedIn`, setup screen 3 or Settings → General).
// - When on: at most once a day (`checkIfDue`), plus "Check Now" on the user's click: one HTTPS GET to the GitHub
//   Releases API for this repository's latest release. No identifiers: a fixed `User-Agent: Kytkin/<version>`, no
//   query, no cookies, no cache (the live client uses an ephemeral session). Only `tag_name` and `html_url` are read.
// - A newer version → one menu line "Update available: Kytkin x.y.z…" that opens the release page in the browser.
//   Kytkin never downloads or installs anything.
// - Stored: only the opt-in and the last check's date. The response is never logged or stored.
// - Any failure (offline, 404 while the repository is private, rate limit, bad JSON) is quiet: nothing shown.

import Foundation
import Observation

/// One HTTPS GET. The live one is `ReleaseHTTPClient` (System); tests use a fake.
protocol HTTPGetting: Sendable {
    /// nil = no answer (offline, timeout, not HTTP).
    func get(_ url: URL, headers: [String: String]) async -> (status: Int, body: Data)?
}

/// A release version: "v1.2.3", "1.2", "1.2.3-beta" (the suffix is ignored for ordering, and a pre-release is never
/// offered: see `UpdateCheck.parse`).
struct SemanticVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let core = t.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: SemanticVersion, b: SemanticVersion) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }
}

/// What the menu shows when a newer release exists.
struct UpdateNotice: Equatable, Sendable {
    let version: String
    let pageURL: URL

    /// The menu line (P6-3).
    var menuTitle: String { "Update available: Kytkin \(version)…" }
}

enum UpdateCheck {
    /// The one repository Kytkin asks about. While it is private, the API answers 404 and the check stays quiet.
    static let repository = "dishontomer5-coder/kytkin"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    static func headers(appVersion: String) -> [String: String] {
        ["User-Agent": "Kytkin/\(appVersion)", "Accept": "application/vnd.github+json"]
    }

    /// `tag_name` and `html_url` of the latest release; nil for anything else (a draft or pre-release, a page that
    /// isn't an https GitHub address, bad JSON).
    static func parse(_ body: Data) -> (version: SemanticVersion, page: URL)? {
        struct Latest: Decodable {
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let latest = try? JSONDecoder().decode(Latest.self, from: body),
              latest.draft != true, latest.prerelease != true,
              let version = SemanticVersion(latest.tag_name),
              let page = URL(string: latest.html_url), page.scheme == "https", page.host == "github.com" else {
            return nil
        }
        return (version, page)
    }

    /// The notice for `body` when it names a version newer than `current`.
    static func notice(for body: Data, current: String) -> UpdateNotice? {
        guard let (latest, page) = parse(body), let mine = SemanticVersion(current), mine < latest else { return nil }
        return UpdateNotice(version: latest.description, pageURL: page)
    }
}

/// P6-3: runs the check (main actor; the GET itself is async). The menu reads `notice`.
@MainActor @Observable final class UpdateChecker {
    enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(UpdateNotice)
        /// Couldn't ask (offline, not public yet, rate limit…): quiet in the menu, said in Settings after Check Now.
        case failed
    }

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private let http: any HTTPGetting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored let appVersion: String
    /// Called when `notice` changes (the menu-bar menu refreshes).
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private(set) var status: Status = .idle
    private var running = false

    init(store: PreferencesStore, http: any HTTPGetting, appVersion: String, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.http = http
        self.appVersion = appVersion
        self.now = now
    }

    /// The menu line, while a newer release is known and the check is still on.
    var notice: UpdateNotice? {
        guard store.prefs.general.updateCheckOptedIn, case .available(let n) = status else { return nil }
        return n
    }

    var isOn: Bool { store.prefs.general.updateCheckOptedIn }

    /// The switch (setup screen 3's box, Settings → General). Turning it on checks if due; off forgets the notice.
    func setOn(_ on: Bool) {
        guard !store.isReadOnly, on != isOn else { return }
        store.update { $0.general.updateCheckOptedIn = on }
        if on {
            Task { await checkIfDue() }
        } else {
            status = .idle
            onChange?()
        }
    }

    /// At most once a day, only when opted in. The app calls it at launch and every hour.
    func checkIfDue() async {
        guard isOn else { return }
        if let last = store.prefs.general.lastUpdateCheck, now().timeIntervalSince(last) < UpdateCheck.minimumInterval,
           now() >= last {
            return
        }
        await check()
    }

    /// "Check Now" (a click), only when opted in.
    func checkNow() async {
        guard isOn else { return }
        await check()
    }

    private func check() async {
        guard !running else { return }
        running = true
        status = .checking
        let answer = await http.get(UpdateCheck.latestReleaseURL, headers: UpdateCheck.headers(appVersion: appVersion))
        running = false
        if !store.isReadOnly { store.update { $0.general.lastUpdateCheck = now() } }
        guard let answer, answer.status == 200 else {
            status = .failed   // 404 while private, 403 rate limit, offline: quiet
            onChange?()
            return
        }
        if let notice = UpdateCheck.notice(for: answer.body, current: appVersion) {
            status = .available(notice)
        } else {
            status = UpdateCheck.parse(answer.body) == nil ? .failed : .upToDate
        }
        onChange?()
    }

    /// Settings → General's line under "Check Now".
    var statusText: String? {
        switch status {
        case .idle: nil
        case .checking: "Checking…"
        case .upToDate: "Kytkin is up to date."
        case .available(let n): "Kytkin \(n.version) is available."
        case .failed: "Couldn't check right now. Kytkin will try again tomorrow."
        }
    }
}
