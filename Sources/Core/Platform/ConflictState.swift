// P2-19: The pure state behind ConflictDetector (001 §2.2). The System adapter only translates
// NSWorkspace notifications and the preference read into `ConflictEvent`s; matching, diffing and change
// detection happen here, unit-tested.
//
// Running switchers are tracked per pid, so one switcher's launch/quit is a diff, two copies of an app
// count once, and a full rescan (launch scan, periodic heal) replaces the whole set.

import Foundation

/// The parts of an `NSRunningApplication` that matter here (Sendable, fakeable).
struct RunningAppInfo: Sendable, Equatable {
    let pid: Int32
    let bundleID: String?
    let name: String?
}

enum ConflictEvent: Sendable, Equatable {
    /// The full list of running apps (start, periodic heal). Replaces what was tracked.
    case scan([RunningAppInfo])
    case launched(RunningAppInfo)
    case terminated(pid: Int32)
    /// A fresh read of the per-document input preference.
    case perDocumentInput(Bool)
}

struct ConflictState: Sendable {
    private(set) var conflicts = Conflicts.none
    private let entries: [KnownSwitcher]
    /// pid → display name, only for apps that are known switchers.
    private var switcherPIDs: [Int32: String] = [:]

    init(entries: [KnownSwitcher] = KnownSwitchers.entries) {
        self.entries = entries
    }

    /// Applies an event. Returns the new `Conflicts` only when it changed (nil = nothing to report).
    @discardableResult
    mutating func apply(_ event: ConflictEvent) -> Conflicts? {
        var next = conflicts
        switch event {
        case .scan(let apps):
            switcherPIDs = [:]
            for app in apps { track(app) }
            next.runningSwitchers = names()
        case .launched(let app):
            track(app)
            next.runningSwitchers = names()
        case .terminated(let pid):
            switcherPIDs[pid] = nil
            next.runningSwitchers = names()
        case .perDocumentInput(let on):
            next.perDocumentInputEnabled = on
        }
        guard next != conflicts else { return nil }
        conflicts = next
        return next
    }

    private mutating func track(_ app: RunningAppInfo) {
        if let hit = KnownSwitchers.match(bundleID: app.bundleID, name: app.name, in: entries) {
            switcherPIDs[app.pid] = hit.name
        } else {
            switcherPIDs[app.pid] = nil   // a reused pid that isn't a switcher any more
        }
    }

    /// Deduplicated, in `entries` order (stable for the menu).
    private func names() -> [String] {
        let hits = Set(switcherPIDs.values)
        return entries.map(\.name).filter(hits.contains)
    }
}
