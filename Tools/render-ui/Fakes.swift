// P6-0a: In-memory fakes for the UI renderer (dev-only, never shipped). Nothing here touches the real preferences
// file, Application Support, TIS, TCC, System Settings, SMAppService, the clipboard or any other app: every
// "request" or "open" call only records that it happened.

import Foundation

/// A clock that never moves.
struct FrozenClock: Clock {
    let nowNanos: UInt64 = 1_000_000_000
}

final class MemoryPreferencesFS: PreferencesFileSystem, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var files: [URL: Data] = [:]

    init(files: [URL: Data] = [:]) { self.files = files }

    func contents(of url: URL) throws -> Data? { lock.withLock { files[url] } }
    func fileExists(at url: URL) -> Bool { lock.withLock { files[url] != nil } }
    func writeAtomically(_ data: Data, to url: URL) throws { lock.withLock { files[url] = data } }
    func moveItem(at source: URL, to destination: URL) throws {
        lock.withLock { files[destination] = files.removeValue(forKey: source) }
    }
    func setOwnerOnlyPermissions(at url: URL) throws {}
}

final class MemoryLayoutFS: LayoutFileSystem, @unchecked Sendable { // @unchecked: guarded by `lock`
    private let lock = NSLock()
    private var files: [URL: Data] = [:]

    init(files: [URL: Data] = [:]) { self.files = files }

    func contents(of url: URL, maxBytes: Int) throws -> Data? { lock.withLock { files[url].map { Data($0.prefix(maxBytes + 1)) } } }
    func size(of url: URL) -> Int? { lock.withLock { files[url]?.count } }
    func jsonFiles(in directory: URL) throws -> [URL] {
        lock.withLock {
            files.keys.filter {
                $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
                    && $0.pathExtension == "json"
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }
    func writeAtomically(_ data: Data, to url: URL) throws { lock.withLock { files[url] = data } }
    func removeItem(at url: URL) throws { _ = lock.withLock { files.removeValue(forKey: url) } }
}

/// System keyboard layouts from the checked-in fixture maps (no TIS).
@MainActor final class FixtureLayouts: LayoutMapProviding {
    var maps: [InputSourceID: LayoutMap] = [:]
    var infos: [InputSourceInfo] = []

    func convertibleLayouts(includeDisabled: Bool) -> [InputSourceInfo] {
        infos.filter { includeDisabled || $0.isEnabled }
    }

    func map(for id: InputSourceID) -> LayoutMap? { maps[id] }
}

@MainActor final class FakeLoginItems: LoginItemManaging {
    var current: LoginItemStatus = .notRegistered
    var status: LoginItemStatus { current }
    func register() throws { current = .enabled }
    func unregister() throws { current = .notRegistered }
    func openSystemSettingsLoginItems() {}
}

/// Permissions with a fixed status. Every request/open is a no-op (no prompt, no System Settings).
@MainActor final class FakePermissions: PermissionsProviding {
    var status = PermissionStatus()
    var onChange: (@MainActor (PermissionStatus) -> Void)?

    func start() {}
    func stop() {}
    func refresh() {}
    func setInteractive(_ visible: Bool) {}
    func requestAccessibility() {}
    func requestInputMonitoring() {}
    func openSystemSettings(_ pane: PermissionPane) {}
    func refreshAutomation(for bundleIDs: Set<String>) {}
    func requestAutomation(for bundleID: String) {}
    func cancelQueuedAutomationRequests() {}
    func openAutomationSettings() {}
}

/// P6-3: the update check's client in the renderer: no network, ever.
struct NoNetwork: HTTPGetting {
    func get(_ url: URL, headers: [String: String]) async -> (status: Int, body: Data)? { nil }
}
