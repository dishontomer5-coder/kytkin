// P2-8: Owns the in-memory Preferences and preferences.json (001 §2.2, §4.1).
//
// Load (in init):
//   - no file → defaults, no issue (first launch).
//   - decodes → use it. Older schema → `.migrated(from:)`, and the original bytes are written to
//     `preferences.v<N>.bak.json` just before the first save. Newer schema → `.newerSchemaReadOnly`.
//   - doesn't decode → moved to `preferences.corrupt-<ISO date>.json`, defaults, `.corruptQuarantined`.
//   - can't be read, or can't be moved aside → defaults, `.unreadable`, read-only (nothing on disk is lost).
// Save: `update` applies the change at once and saves 0.5 s after the last change (debounced, measured
// on the injected Clock), atomically with mode 0600. `flush()` saves now (on quit).
// Read-only: changes still apply in memory for this session, but the file is never written.

import Foundation
import Observation

@MainActor @Observable final class PreferencesStore {
    static let debounceNanos: UInt64 = 500_000_000

    private(set) var prefs: Preferences
    private(set) var loadIssue: PreferencesLoadIssue?
    /// True when the file must never be written (newer schema, or unreadable).
    private(set) var isReadOnly = false
    /// The last save threw. Cleared by the next successful save.
    private(set) var lastSaveFailed = false

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let fileSystem: any PreferencesFileSystem
    @ObservationIgnored private let migrator: PreferencesMigrator
    @ObservationIgnored private let debounceNanos: UInt64
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var saveDeadlineNanos: UInt64 = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The original bytes of a migrated file, written to the .bak before the first save.
    @ObservationIgnored private var pendingBackup: (data: Data, version: Int)?

    convenience init(fileURL: URL, clock: any Clock) {
        self.init(fileURL: fileURL, clock: clock, fileSystem: LocalPreferencesFileSystem())
    }

    /// `now` names a quarantined file. `migrator` and `debounceNanos` exist for tests.
    init(fileURL: URL, clock: any Clock, fileSystem: any PreferencesFileSystem,
         migrator: PreferencesMigrator = .standard, debounceNanos: UInt64 = PreferencesStore.debounceNanos,
         now: () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        self.fileSystem = fileSystem
        self.migrator = migrator
        self.debounceNanos = debounceNanos
        self.prefs = Preferences()

        let data: Data?
        do {
            data = try fileSystem.contents(of: fileURL)
        } catch {
            loadIssue = .unreadable
            isReadOnly = true
            return
        }
        guard let data else { return }

        do {
            let decoded = try PreferencesCodec.decodeDetailed(data, migrator: migrator)
            prefs = decoded.prefs
            if decoded.newerSchemaVersion != nil {
                loadIssue = .newerSchemaReadOnly
                isReadOnly = true
            } else if let from = decoded.migratedFrom {
                loadIssue = .migrated(from: from)
                pendingBackup = (data, from)
            }
        } catch {
            quarantine(at: now())
        }
    }

    /// Applies `change` now and schedules a debounced save. A change that leaves Preferences equal is a no-op.
    func update(_ change: (inout Preferences) -> Void) {
        var next = prefs
        change(&next)
        guard next != prefs else { return }
        prefs = next
        guard !isReadOnly else { return }
        isDirty = true
        saveDeadlineNanos = clock.nowNanos &+ debounceNanos
        scheduleSave()
    }

    /// Saves pending changes now (on quit).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty { save() }
    }

    /// Saves if the debounce deadline has passed on the clock. Returns the nanoseconds still to wait,
    /// or nil when nothing is pending. The scheduled task calls this; tests call it with a FakeClock.
    @discardableResult
    func saveIfDue() -> UInt64? {
        guard isDirty else { return nil }
        let now = clock.nowNanos
        if now < saveDeadlineNanos { return saveDeadlineNanos - now }
        save()
        return nil
    }

    // MARK: - Private

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let first = debounceNanos
        saveTask = Task { [weak self] in
            var wait = first
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: wait)
                guard !Task.isCancelled, let store = self else { return }
                guard let remaining = store.saveIfDue() else {
                    store.saveTask = nil
                    return
                }
                wait = remaining
            }
        }
    }

    private func save() {
        guard !isReadOnly else { return }
        do {
            if let backup = pendingBackup {
                let url = PreferencesLocation.backupURL(for: fileURL, version: backup.version)
                try fileSystem.writeAtomically(backup.data, to: url)
                pendingBackup = nil
            }
            let data = try PreferencesCodec.encode(prefs, schemaVersion: migrator.currentVersion)
            try fileSystem.writeAtomically(data, to: fileURL)
            isDirty = false
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
    }

    private func quarantine(at date: Date) {
        let first = PreferencesLocation.quarantineURL(for: fileURL, at: date)
        let stem = first.deletingPathExtension().lastPathComponent
        var dest = first
        var n = 2
        // Two corrupt loads in the same second must not overwrite the first quarantined copy.
        while fileSystem.fileExists(at: dest) {
            dest = first.deletingLastPathComponent().appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        do {
            try fileSystem.moveItem(at: fileURL, to: dest)
            loadIssue = .corruptQuarantined(dest)
        } catch {
            loadIssue = .unreadable
            isReadOnly = true
        }
    }
}
