// P2-8: Owns the in-memory Preferences and preferences.json (001 §2.2, §4.1).
//
// Load (in init):
//   - no file → defaults, no issue (first launch). `foundFileAtLoad` stays false only in this case (P3-12).
//   - decodes → use it. Older schema → `.migrated(from:)`, and the original bytes are written to
//     `preferences.v<N>.bak.json` just before the first save. Newer schema → `.newerSchemaReadOnly`.
//   - decodes, but leniency dropped or defaulted something (a bad rule, a mistyped field…) →
//     `loadWasLossy`, and the original bytes are written to `preferences.lossy-<ISO date>.bak.json`
//     just before the first save (a migrated file's `.v<N>.bak.json` already is that copy).
//   - doesn't decode → moved to `preferences.corrupt-<ISO date>.json` (set to 0600, best effort), defaults,
//     `.corruptQuarantined`.
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
    /// The file loaded, but some entries or fields in it couldn't be read and were dropped or reset to
    /// their defaults. Settings tells the user; `originalBackupURL` says where the original is kept.
    private(set) var loadWasLossy = false
    /// Where the untouched original of a lossy or migrated file was copied, once the first save did it.
    private(set) var originalBackupURL: URL?
    /// P3-12: a preferences file was there when this store loaded (good, migrated, lossy, newer, corrupt or
    /// unreadable alike). False only on a true first launch (or after the user deleted the file). Never changes.
    @ObservationIgnored private(set) var foundFileAtLoad = false

    @ObservationIgnored let fileURL: URL
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let fileSystem: any PreferencesFileSystem
    @ObservationIgnored private let migrator: PreferencesMigrator
    @ObservationIgnored private let debounceNanos: UInt64
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var saveDeadlineNanos: UInt64 = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    /// The original bytes of a migrated or lossy file, and where they go before the first save.
    @ObservationIgnored private var pendingBackup: PendingBackup?

    private enum PendingBackup {
        case migrated(Data, version: Int)
        case lossy(Data)
    }

    convenience init(fileURL: URL, clock: any Clock) {
        self.init(fileURL: fileURL, clock: clock, fileSystem: LocalPreferencesFileSystem())
    }

    /// `now` names a quarantined file and a lossy backup. `migrator` and `debounceNanos` exist for tests.
    init(fileURL: URL, clock: any Clock, fileSystem: any PreferencesFileSystem,
         migrator: PreferencesMigrator = .standard, debounceNanos: UInt64 = PreferencesStore.debounceNanos,
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.clock = clock
        self.fileSystem = fileSystem
        self.migrator = migrator
        self.debounceNanos = debounceNanos
        self.now = now
        self.prefs = Preferences()

        let data: Data?
        do {
            data = try fileSystem.contents(of: fileURL)
        } catch {
            foundFileAtLoad = true   // P3-12: something is there, we just can't read it
            loadIssue = .unreadable
            isReadOnly = true
            return
        }
        guard let data else { return }
        foundFileAtLoad = true

        do {
            let decoded = try PreferencesCodec.decodeDetailed(data, migrator: migrator)
            prefs = decoded.prefs
            loadWasLossy = decoded.isLossy
            if decoded.newerSchemaVersion != nil {
                loadIssue = .newerSchemaReadOnly
                isReadOnly = true
            } else if let from = decoded.migratedFrom {
                loadIssue = .migrated(from: from)
                pendingBackup = .migrated(data, version: from)
            } else if decoded.isLossy {
                pendingBackup = .lossy(data)
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
            // The original is copied first; if that fails, the file isn't overwritten either.
            switch pendingBackup {
            case .migrated(let data, let version):
                // P2-37: `-N` suffix if taken (001 §12 S4).
                let url = firstFreeURL { PreferencesLocation.backupURL(for: fileURL, version: version, attempt: $0) }
                try fileSystem.writeAtomically(data, to: url)
                originalBackupURL = url
            case .lossy(let data):
                let date = now()
                let url = firstFreeURL { PreferencesLocation.lossyBackupURL(for: fileURL, at: date, attempt: $0) }
                try fileSystem.writeAtomically(data, to: url)
                originalBackupURL = url
            case nil:
                break
            }
            pendingBackup = nil
            let data = try PreferencesCodec.encode(prefs, schemaVersion: migrator.currentVersion)
            try fileSystem.writeAtomically(data, to: fileURL)
            isDirty = false
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
    }

    /// The first `name(1)`, `name(2)`… that doesn't exist yet, so two quarantines or backups in the same
    /// second never overwrite each other.
    private func firstFreeURL(_ name: (Int) -> URL) -> URL {
        var attempt = 1
        while fileSystem.fileExists(at: name(attempt)) { attempt += 1 }
        return name(attempt)
    }

    private func quarantine(at date: Date) {
        // moveItem fails rather than replace an existing file, so a name taken in between is safe too.
        let dest = firstFreeURL { PreferencesLocation.quarantineURL(for: fileURL, at: date, attempt: $0) }
        do {
            try fileSystem.moveItem(at: fileURL, to: dest)
            loadIssue = .corruptQuarantined(dest)
        } catch {
            loadIssue = .unreadable
            isReadOnly = true
            return
        }
        // P2-37: moveItem keeps the old mode, and a hand-edited file may be 0644 (001 §12 S5). Best effort:
        // a failure is ignored and doesn't change the load, since the file was already the user's.
        try? fileSystem.setOwnerOnlyPermissions(at: dest)
    }
}
